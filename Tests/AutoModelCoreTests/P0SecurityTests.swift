import Foundation
import Security
import XCTest
@testable import AutoModelCore

final class P0SecurityTests: XCTestCase {
    func testPrivacyBodyRecordingMigrationDefaultsOffAndPreservesExplicitChoices() throws {
        let missing = try JSONDecoder().decode(PrivacySettings.self, from: Data(#"{"hasCompletedOnboarding":true}"#.utf8))
        XCTAssertFalse(missing.recordRequestBody)
        XCTAssertTrue(missing.hasCompletedOnboarding)

        let enabled = try JSONDecoder().decode(PrivacySettings.self, from: Data(#"{"recordRequestBody":true}"#.utf8))
        let disabled = try JSONDecoder().decode(PrivacySettings.self, from: Data(#"{"recordRequestBody":false}"#.utf8))
        XCTAssertTrue(enabled.recordRequestBody)
        XCTAssertFalse(disabled.recordRequestBody)
        XCTAssertFalse(PrivacySettings().recordRequestBody)
    }

    func testLocalTokenGenerationAndConstantTimeVerification() throws {
        let keychain = InMemoryKeychainService()
        let token = try LocalAPITokenManager.loadOrCreate(keychain: keychain)
        XCTAssertGreaterThanOrEqual(token.count, 43)
        XCTAssertEqual(try keychain.getLocalAPIToken(), token)
        XCTAssertEqual(try LocalAPITokenManager.loadOrCreate(keychain: keychain), token)
        XCTAssertTrue(LocalAPITokenManager.constantTimeEquals(token, token))
        XCTAssertFalse(LocalAPITokenManager.constantTimeEquals(token, token + "x"))
        XCTAssertTrue(keychain.allKnownSecretValues().contains(token))
    }

    func testUnifiedRequestSecurityBoundary() {
        let token = String(repeating: "a", count: 44)
        let validHeaders = [
            "Host": "127.0.0.1:8765",
            "Authorization": "Bearer \(token)"
        ]

        XCTAssertNil(LocalAPIRequestSecurity.rejection(
            for: request(path: "/v1/models", headers: validHeaders), port: 8765, token: token
        ))
        XCTAssertNil(LocalAPIRequestSecurity.rejection(
            for: request(path: "/v1/messages", headers: ["Host": "localhost:8765", "x-api-key": token]),
            port: 8765,
            token: token
        ))

        assertRejection(path: "/v1/models", headers: ["Host": "127.0.0.1:8765"], status: 401, code: "unauthorized", token: token)
        assertRejection(path: "/v1/chat/completions", headers: ["Host": "127.0.0.1:8765", "Authorization": "Bearer wrong"], status: 401, code: "unauthorized", token: token)
        assertRejection(path: "/api/local/receipts", headers: ["Host": "127.0.0.1:8765"], status: 401, code: "unauthorized", token: token)
        assertRejection(path: "/api/local/strategy", method: "POST", headers: ["Host": "127.0.0.1:8765"], status: 401, code: "unauthorized", token: token)
        assertRejection(path: "/api/local/tiers", method: "POST", headers: ["Host": "127.0.0.1:8765"], status: 401, code: "unauthorized", token: token)
        assertRejection(path: "/v1/models", headers: ["Host": "evil.example", "Authorization": "Bearer \(token)"], status: 403, code: "invalid_host", token: token)
        assertRejection(path: "/v1/models", headers: validHeaders.merging(["Origin": "https://evil.example"]) { _, new in new }, status: 403, code: "invalid_origin", token: token)
        assertRejection(path: "/v1/models", method: "OPTIONS", headers: ["Host": "127.0.0.1:8765"], status: 401, code: "unauthorized", token: token)

        XCTAssertNil(LocalAPIRequestSecurity.rejection(
            for: request(path: "/health", headers: ["Host": "127.0.0.1:8765"]), port: 8765, token: token
        ))
    }

    func testAgentIntegrationWritesLocalTokenInsteadOfSharedPlaceholder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("autoroute-p0-agent-\(UUID().uuidString)")
        let backups = home.appendingPathComponent("backups")
        defer { try? FileManager.default.removeItem(at: home) }
        let service = AgentConfigService(homeDirectory: home, backupDirectory: backups)
        let token = "local-token-256-bit-test-value"

        for kind in [AgentKind.codex, .opencode, .claudeCode, .hermes, .shellAndContinue] {
            _ = try service.applyAgentConfig(
                kind: kind,
                binding: AgentModelBinding(),
                proxyPort: 8765,
                localAPIToken: token
            )
            let contents = try String(contentsOf: service.primaryConfigURL(for: kind), encoding: .utf8)
            XCTAssertTrue(contents.contains(token), kind.rawValue)
            XCTAssertFalse(contents.contains("automodel-local"), kind.rawValue)
        }
    }

    @MainActor
    func testDisabledBodyRecordingKeepsUpstreamErrorBodyOutOfPersistedData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autoroute-p0-error-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = "UPSTREAM-HTTP-400-SENTINEL-DO-NOT-PERSIST"
        let upstream = LocalTestUpstreamServer(
            behavior: .init(failModelsWithStatus: ["sensitive-model": (400, sentinel)])
        )
        let port = try upstream.start(port: 0)
        defer { upstream.stop() }
        let store = LocalPersistenceStore(baseDirectoryURL: directory)
        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        let provider = ProviderConfig(
            name: "Sensitive Real Upstream",
            baseURL: "http://127.0.0.1:\(port)",
            isEnabled: true,
            timeoutSeconds: 10,
            healthStatus: .healthy
        )
        try engine.upsertProvider(provider, apiKey: "sensitive-provider-key")
        engine.upsertModel(ModelConfig(
            providerID: provider.id,
            modelID: "sensitive-model",
            capabilities: [.chat],
            availabilityStatus: .available
        ))
        let payload: [String: Any] = [
            "model": "sensitive-model",
            "messages": [["role": "user", "content": "public error test"]]
        ]

        let outcome = await engine.executeChatCompletion(payload: payload, source: .externalProxy)
        XCTAssertEqual(outcome.httpStatusCode, 400)
        XCTAssertTrue(String(decoding: outcome.responseBody, as: UTF8.self).contains(sentinel), "client can receive the detailed upstream error")

        let safeRecord = outcome.callRecord
        XCTAssertFalse(safeRecord.errorMessage?.contains(sentinel) == true)
        XCTAssertFalse(safeRecord.attempts.contains { $0.errorMessage?.contains(sentinel) == true })
        XCTAssertFalse(engine.config.providers.first?.lastErrorMessage?.contains(sentinel) == true)
        XCTAssertFalse(engine.config.models.first?.lastAvailabilityNote?.contains(sentinel) == true)
        XCTAssertFalse(try String(contentsOf: store.historyFileURL, encoding: .utf8).contains(sentinel))
        XCTAssertFalse(try String(contentsOf: store.configFileURL, encoding: .utf8).contains(sentinel))
        let exported = try store.exportReceiptsJSON(records: engine.callHistory, secretsToRedact: [])
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains(sentinel))

        engine.setRecordRequestBody(true)
        let detailed = await engine.executeChatCompletion(payload: payload, source: .externalProxy)
        XCTAssertTrue(detailed.callRecord.errorMessage?.contains(sentinel) == true)
        XCTAssertTrue(try String(contentsOf: store.historyFileURL, encoding: .utf8).contains(sentinel))
    }

    func testCodexInjectionUsesLocalBearerWithoutOpenAIAuthRequirement() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("autoroute-p0-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let service = AgentConfigService(
            homeDirectory: home,
            backupDirectory: home.appendingPathComponent("backups")
        )
        let token = "local-bearer-token-for-codex-test"
        _ = try service.applyAgentConfig(
            kind: .codex,
            binding: AgentModelBinding(),
            proxyPort: 28765,
            localAPIToken: token
        )
        let text = try String(contentsOf: service.primaryConfigURL(for: .codex), encoding: .utf8)
        XCTAssertTrue(text.contains("http_headers"))
        XCTAssertTrue(text.contains("Bearer \(token)"))
        XCTAssertFalse(text.contains("requires_openai_auth = true"))
    }

    @MainActor
    func testRealHTTPAuthenticationAndBodyRecordingLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autoroute-p0-http-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPersistenceStore(baseDirectoryURL: directory)
        let keychain = InMemoryKeychainService()
        let upstream = LocalTestUpstreamServer()
        let upstreamPort = try upstream.start(port: 0)
        defer { upstream.stop() }
        let engine = AutoModelEngine(persistence: store, keychain: keychain, autoStartProxyIfConfigured: false)
        let provider = ProviderConfig(name: "P0 Mock", baseURL: "http://127.0.0.1:\(upstreamPort)")
        try engine.upsertProvider(provider, apiKey: "provider-secret")
        engine.upsertModel(ModelConfig(providerID: provider.id, modelID: "mock-fast-mini", capabilities: [.chat]))
        let port = try XCTUnwrap(LoopbackHTTPServer.findAvailablePort(startingFrom: 21_100))
        engine.updateProxyPort(port)
        engine.startProxy()
        defer { engine.stopProxy() }

        let root = URL(string: "http://127.0.0.1:\(port)")!
        let anonymousModels = try await URLSession.shared.data(from: root.appendingPathComponent("v1/models"))
        XCTAssertEqual((anonymousModels.1 as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertFalse(String(data: anonymousModels.0, encoding: .utf8)?.contains("mock-fast-mini") == true)
        XCTAssertTrue(engine.callHistory.isEmpty)

        let health = try await URLSession.shared.data(from: root.appendingPathComponent("health"))
        let healthJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: health.0) as? [String: Any])
        XCTAssertEqual((health.1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(Set(healthJSON.keys), Set(["status", "app"]))

        var preflight = URLRequest(url: root.appendingPathComponent("v1/models"))
        preflight.httpMethod = "OPTIONS"
        preflight.setValue("Bearer \(engine.localAPIToken)", forHTTPHeaderField: "Authorization")
        let preflightResponse = try await URLSession.shared.data(for: preflight).1 as? HTTPURLResponse
        XCTAssertEqual(preflightResponse?.statusCode, 204)
        XCTAssertNil(preflightResponse?.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))

        func sendChat() async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: root.appendingPathComponent("v1/chat/completions"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(engine.localAPIToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "auto",
                "messages": [["role": "user", "content": "private-body-sentinel"]]
            ])
            let result = try await URLSession.shared.data(for: request)
            return (result.0, try XCTUnwrap(result.1 as? HTTPURLResponse))
        }

        let defaultResult = try await sendChat()
        XCTAssertEqual(defaultResult.1.statusCode, 200)
        XCTAssertNil(engine.callHistory.first?.requestPreview)
        XCTAssertNil(engine.callHistory.first?.responsePreview)
        XCTAssertFalse(try String(contentsOf: store.historyFileURL, encoding: .utf8).contains("private-body-sentinel"))

        engine.setRecordRequestBody(true)
        _ = try await sendChat()
        XCTAssertEqual(engine.callHistory.first?.requestPreview?.contains("private-body-sentinel"), true)
        engine.setRecordRequestBody(false)
        _ = try await sendChat()
        XCTAssertNil(engine.callHistory.first?.requestPreview)
        XCTAssertNil(engine.callHistory.first?.responsePreview)

        let export = try store.exportReceiptsJSON(records: engine.callHistory, secretsToRedact: keychain.allKnownSecretValues())
        let exportText = String(data: export, encoding: .utf8) ?? ""
        XCTAssertFalse(exportText.contains(engine.localAPIToken))
        XCTAssertFalse(exportText.contains("provider-secret"))
    }

    func testReleaseSigningPreparationRefusesNonGitHubActionsExecution() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let prepare = try String(
            contentsOf: root.appendingPathComponent("macos/prepare_release_signing.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(prepare.contains("GITHUB_ACTIONS"))
        XCTAssertTrue(prepare.contains("CI-only"))
        let checklist = try String(
            contentsOf: root.appendingPathComponent("docs/release/RELEASE_CHECKLIST.md"),
            encoding: .utf8
        )
        XCTAssertTrue(checklist.contains("GITHUB_ACTIONS"))
    }

    func testReleaseWorkflowRejectsTagVersionMismatchBeforeBuild() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let release = try String(contentsOf: root.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        XCTAssertTrue(release.contains("Verify tag matches version.env"))
        XCTAssertTrue(release.contains("source macos/version.env"))
        XCTAssertTrue(release.contains(#"expected_tag="v${AUTOROUTE_VERSION}""#))
        XCTAssertTrue(release.contains("GITHUB_REF_NAME"))
        XCTAssertTrue(release.contains("Release refused: tag"))

        let tagCheck = try XCTUnwrap(release.range(of: "Verify tag matches version.env"))
        for laterStep in [
            "bash macos/build_app.sh",
            "bash macos/package_app.sh",
            "bash macos/notarize_app.sh",
            "Publish GitHub Release assets"
        ] {
            let laterRange = try XCTUnwrap(release.range(of: laterStep), "missing \(laterStep)")
            XCTAssertLessThan(tagCheck.lowerBound, laterRange.lowerBound, "tag/version check must precede \(laterStep)")
        }
    }

    func testBuildMetadataAndReleaseScriptsArePresentAndSafe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let version = try String(contentsOf: root.appendingPathComponent("macos/version.env"), encoding: .utf8)
        XCTAssertTrue(version.contains("AUTOROUTE_VERSION="))
        XCTAssertTrue(version.contains("AUTOROUTE_BUILD_NUMBER="))
        let build = try String(contentsOf: root.appendingPathComponent("macos/build_app.sh"), encoding: .utf8)
        XCTAssertFalse(build.contains("NSAllowsArbitraryLoads"))
        XCTAssertTrue(build.contains("DEVELOPER_ID_APPLICATION"))
        XCTAssertTrue(build.contains("codesign --verify"))
        for script in ["macos/package_app.sh", "macos/notarize_app.sh", "macos/generate_homebrew_cask.sh"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(script).path), script)
        }
        let ci = try String(contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        XCTAssertTrue(ci.contains("swift test"))
        XCTAssertTrue(ci.contains("macos/build_app.sh"))
        XCTAssertTrue(ci.contains("git diff --check"))
        let release = try String(contentsOf: root.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        XCTAssertTrue(release.contains("DEVELOPER_ID_APPLICATION"))
        XCTAssertTrue(release.contains("NOTARYTOOL_KEYCHAIN_PROFILE"))
        XCTAssertFalse(release.contains("codesign --force --deep --sign -"))
    }

    func testReleaseWorkflowImportsCertificateAndConfiguresTemporaryNotaryKeychain() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let prepare = try String(contentsOf: root.appendingPathComponent("macos/prepare_release_signing.sh"), encoding: .utf8)
        for required in [
            "DEVELOPER_ID_CERTIFICATE_P12_BASE64", "DEVELOPER_ID_CERTIFICATE_PASSWORD",
            "NOTARYTOOL_APPLE_ID", "NOTARYTOOL_APPLE_PASSWORD", "NOTARYTOOL_TEAM_ID",
            "mktemp -d", "umask 077", "base64 --decode", "security create-keychain",
            "security import", "set-key-partition-list", "security find-identity",
            "notarytool store-credentials", "--keychain", "GITHUB_ENV", "--validate"
        ] {
            XCTAssertTrue(prepare.contains(required), "release preparation missing \(required)")
        }
        let cleanup = try String(contentsOf: root.appendingPathComponent("macos/cleanup_release_signing.sh"), encoding: .utf8)
        XCTAssertTrue(cleanup.contains("security delete-keychain"))
        XCTAssertTrue(cleanup.contains("AUTOROUTE_RELEASE_TEMP_DIR"))
        XCTAssertFalse(prepare.contains("set -x"))

        let build = try String(contentsOf: root.appendingPathComponent("macos/build_app.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("AUTOROUTE_REQUIRE_DEVELOPER_ID"))
        XCTAssertTrue(build.contains("Authority="))
        let notarize = try String(contentsOf: root.appendingPathComponent("macos/notarize_app.sh"), encoding: .utf8)
        XCTAssertTrue(notarize.contains("AUTOROUTE_NOTARY_KEYCHAIN"))
        XCTAssertTrue(notarize.contains("--keychain"))
        XCTAssertTrue(notarize.contains("stapler staple"))

        let release = try String(contentsOf: root.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        for required in [
            "DEVELOPER_ID_CERTIFICATE_P12_BASE64", "DEVELOPER_ID_CERTIFICATE_PASSWORD",
            "NOTARYTOOL_APPLE_ID", "NOTARYTOOL_APPLE_PASSWORD", "NOTARYTOOL_TEAM_ID",
            "prepare_release_signing.sh", "cleanup_release_signing.sh", "AUTOROUTE_REQUIRE_DEVELOPER_ID"
        ] {
            XCTAssertTrue(release.contains(required), "release workflow missing \(required)")
        }
        XCTAssertFalse(release.contains("NOTARYTOOL_KEYCHAIN_PROFILE: ${{ secrets.NOTARYTOOL_KEYCHAIN_PROFILE }}"))
        XCTAssertTrue(release.contains("bash macos/package_app.sh"))
        XCTAssertTrue(release.contains("if: ${{ always() }}"))
        let packageRange = try XCTUnwrap(release.range(of: "bash macos/package_app.sh"))
        let notarizeRange = try XCTUnwrap(release.range(of: "bash macos/notarize_app.sh"))
        XCTAssertLessThan(packageRange.lowerBound, notarizeRange.lowerBound, "release must package a fresh ZIP before notarization")
        let packageScript = try String(contentsOf: root.appendingPathComponent("macos/package_app.sh"), encoding: .utf8)
        XCTAssertTrue(packageScript.contains(#"cd "$ROOT_DIR/dist""#))
        XCTAssertTrue(packageScript.contains(#"shasum -a 256 "$ZIP_NAME""#))
        XCTAssertFalse(packageScript.contains(#"shasum -a 256 "$ZIP_PATH""#))
        let checklist = try String(contentsOf: root.appendingPathComponent("docs/release/RELEASE_CHECKLIST.md"), encoding: .utf8)
        for required in ["DEVELOPER_ID_CERTIFICATE_P12_BASE64", "DEVELOPER_ID_CERTIFICATE_PASSWORD", "NOTARYTOOL_APPLE_ID", "NOTARYTOOL_APPLE_PASSWORD", "NOTARYTOOL_TEAM_ID", "prepare_release_signing.sh"] {
            XCTAssertTrue(checklist.contains(required), "release checklist missing \(required)")
        }
        XCTAssertTrue(checklist.contains("tag") && checklist.contains("仅凭"))
    }

    @MainActor
    func testUnpersistedLocalTokenBlocksAutoProxyAndAgentWritesUntilRecovery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRouteTokenPersistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = ThrowingLocalTokenKeychain()
        keychain.failLocalTokenWrites = true
        let agentHome = directory.appendingPathComponent("home", isDirectory: true)
        let engine = AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: directory.appendingPathComponent("data")),
            keychain: keychain,
            agentConfigService: AgentConfigService(
                homeDirectory: agentHome,
                backupDirectory: directory.appendingPathComponent("backups")
            ),
            autoStartProxyIfConfigured: true
        )
        defer { engine.stopProxy(); engine.stopBackgroundTasks() }

        XCTAssertFalse(engine.isLocalAPITokenPersistent)
        XCTAssertFalse(engine.proxyState.isRunning)
        XCTAssertFalse(keychain.hasPersistedLocalToken)
        XCTAssertThrowsError(try engine.applyAgentIntegration(kind: .codex)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Keychain"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: agentHome.appendingPathComponent(".codex/config.toml").path
        ))

        keychain.failLocalTokenWrites = false
        try engine.retryPersistingLocalAPIToken()
        XCTAssertTrue(engine.isLocalAPITokenPersistent)
        XCTAssertEqual(try keychain.getLocalAPIToken(), engine.localAPIToken)
        XCTAssertTrue(keychain.hasPersistedLocalToken)

        let port = try XCTUnwrap(LoopbackHTTPServer.findAvailablePort(startingFrom: 23_700))
        engine.updateProxyPort(port)
        XCTAssertTrue(engine.proxyState.isRunning)
    }

    private func request(path: String, method: String = "GET", headers: [String: String]) -> HTTPRequestMessage {
        HTTPRequestMessage(method: method, path: path, query: "", headers: headers, body: Data())
    }

    private func assertRejection(
        path: String,
        method: String = "GET",
        headers: [String: String],
        status: Int,
        code: String,
        token: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rejection = LocalAPIRequestSecurity.rejection(
            for: request(path: path, method: method, headers: headers), port: 8765, token: token
        )
        XCTAssertEqual(rejection?.statusCode, status, file: file, line: line)
        XCTAssertEqual(rejection?.code, code, file: file, line: line)
    }
}

private final class ThrowingLocalTokenKeychain: KeychainServiceProtocol, @unchecked Sendable {
    var failLocalTokenWrites = false
    private var keys: [UUID: String] = [:]
    private var localToken: String?

    var hasPersistedLocalToken: Bool { localToken?.isEmpty == false }

    func setAPIKey(_ key: String, for providerID: UUID) throws { keys[providerID] = key }
    func getAPIKey(for providerID: UUID) throws -> String? { keys[providerID] }
    func deleteAPIKey(for providerID: UUID) throws { keys.removeValue(forKey: providerID) }
    func hasAPIKey(for providerID: UUID) -> Bool { keys[providerID]?.isEmpty == false }

    func setLocalAPIToken(_ token: String) throws {
        if failLocalTokenWrites {
            throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
        }
        localToken = token
    }

    func getLocalAPIToken() throws -> String? { localToken }
    func allKnownSecretValues() -> [String] { Array(keys.values) + [localToken].compactMap { $0 } }
    func clearAll() throws { keys.removeAll(); localToken = nil }
}
