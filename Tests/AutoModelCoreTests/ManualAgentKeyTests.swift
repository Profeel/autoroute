import Foundation
import Security
import XCTest
@testable import AutoModelCore

private final class ModelKeyFailureStore: KeychainServiceProtocol, @unchecked Sendable {
    let inner = InMemoryKeychainService()
    var failRead = false
    var failWrite = false
    var failDelete = false
    var failClear = false
    func setAPIKey(_ key: String, for id: UUID) throws { try inner.setAPIKey(key, for: id) }
    func getAPIKey(for id: UUID) throws -> String? { try inner.getAPIKey(for: id) }
    func cachedAPIKey(for id: UUID) -> CachedAPIKey { inner.cachedAPIKey(for: id) }
    func deleteAPIKey(for id: UUID) throws { try inner.deleteAPIKey(for: id) }
    func hasAPIKey(for id: UUID) -> Bool { inner.hasAPIKey(for: id) }
    func setLocalAPIToken(_ token: String) throws { try inner.setLocalAPIToken(token) }
    func getLocalAPIToken() throws -> String? { try inner.getLocalAPIToken() }
    func setLocalModelAPIKey(_ key: String) throws {
        if failWrite { throw KeychainError.unexpectedStatus(errSecAuthFailed) }
        try inner.setLocalModelAPIKey(key)
    }
    func getLocalModelAPIKey() throws -> String? {
        if failRead { throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed) }
        return try inner.getLocalModelAPIKey()
    }
    func deleteLocalModelAPIKey() throws {
        if failDelete { throw KeychainError.unexpectedStatus(errSecAuthFailed) }
        try inner.deleteLocalModelAPIKey()
    }
    func allKnownSecretValues() -> [String] { inner.allKnownSecretValues() }
    func clearAll() throws {
        if failClear { throw KeychainError.unexpectedStatus(errSecAuthFailed) }
        try inner.clearAll()
    }
}

final class ManualAgentKeyTests: XCTestCase {
    @MainActor
    private func engine(_ directory: URL, keychain: any KeychainServiceProtocol) -> AutoModelEngine {
        AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: directory.appendingPathComponent("data")),
            keychain: keychain,
            agentConfigService: AgentConfigService(
                homeDirectory: directory.appendingPathComponent("home"),
                backupDirectory: directory.appendingPathComponent("backups")
            ),
            alertNotifier: NoOpSystemAlertNotifier(),
            autoStartProxyIfConfigured: false
        )
    }

    func testDedicatedMacOSKeychainItemCanRotateAndClear() throws {
        guard ProcessInfo.processInfo.environment["AUTOROUTE_KEYCHAIN_SMOKE_TEST"] == "1" else {
            throw XCTSkip("Set AUTOROUTE_KEYCHAIN_SMOKE_TEST=1 on a host with an unlocked Keychain.")
        }
        let service = "org.automodel.test.manual-key.\(UUID().uuidString)"
        let keys = MacOSKeychainService(service: service)
        defer { try? keys.clearAll() }
        let provider = UUID()
        try keys.setAPIKey("provider-key", for: provider)
        try keys.setLocalModelAPIKey("first-key")
        try keys.setLocalModelAPIKey("second-key")
        let reopened = MacOSKeychainService(service: service)
        XCTAssertEqual(try reopened.getLocalModelAPIKey(), "second-key")
        XCTAssertEqual(try MacOSKeychainService(service: service).getAPIKey(for: provider), "provider-key")
        XCTAssertTrue(reopened.allKnownSecretValues().contains("second-key"))
        try reopened.deleteLocalModelAPIKey()
        XCTAssertNil(try reopened.getLocalModelAPIKey())
        XCTAssertEqual(try reopened.getAPIKey(for: provider), "provider-key")
    }

    @MainActor
    func testValidationPersistenceFailuresAndRedaction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("manual-agent-key-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = ModelKeyFailureStore()
        try keys.setLocalAPIToken("management-token")
        try keys.setLocalModelAPIKey("first-key")
        keys.failRead = true
        let app = engine(dir, keychain: keys)
        XCTAssertTrue(app.isLocalAPITokenPersistent)
        XCTAssertNotNil(app.localModelAPIKeyError)
        XCTAssertNil(app.manualAgentAPIKey)
        XCTAssertEqual(try keys.inner.getLocalModelAPIKey(), "first-key")
        let port = try XCTUnwrap(LoopbackHTTPServer.findAvailablePort(startingFrom: 25_600))
        app.updateProxyPort(port)
        app.startProxy()
        XCTAssertTrue(app.proxyState.isRunning)
        app.stopProxy()
        keys.failRead = false
        try app.reloadLocalModelAPIKey()
        XCTAssertEqual(app.manualAgentAPIKey, "first-key")
        XCTAssertNoThrow(try LocalModelAPIKeyError.validate("a._~", managementToken: app.localAPIToken))
        XCTAssertNoThrow(try LocalModelAPIKeyError.validate(String(repeating: "a", count: 128), managementToken: app.localAPIToken))

        for invalid in ["", "abc", "has space", "ab\ncd", "中文密钥", String(repeating: "a", count: 129), "management-token"] {
            XCTAssertThrowsError(try app.setLocalModelAPIKey(invalid))
            XCTAssertEqual(app.localModelAPIKey, "first-key")
        }
        keys.failWrite = true
        XCTAssertThrowsError(try app.setLocalModelAPIKey("second-key"))
        XCTAssertEqual(app.localModelAPIKey, "first-key")
        XCTAssertEqual(try keys.inner.getLocalModelAPIKey(), "first-key")
        keys.failWrite = false
        keys.failDelete = true
        XCTAssertThrowsError(try app.clearLocalModelAPIKey())
        XCTAssertEqual(app.localModelAPIKey, "first-key")
        keys.failRead = true
        XCTAssertThrowsError(try app.reloadLocalModelAPIKey())
        XCTAssertEqual(app.localModelAPIKey, "first-key")
        XCTAssertNotNil(app.localModelAPIKeyError)
        keys.failClear = true
        XCTAssertThrowsError(try app.clearAllKeychainKeys())
        XCTAssertEqual(app.localModelAPIKey, "first-key")
        XCTAssertNotNil(app.localModelAPIKeyError)
        XCTAssertTrue(keys.allKnownSecretValues().contains("first-key"))
        XCTAssertEqual(SecretRedactor.redact("first-key", secrets: keys.allKnownSecretValues()), "[REDACTED_KEY]")
        keys.failClear = false
        try app.clearAllKeychainKeys()
        XCTAssertNil(app.localModelAPIKey)
        XCTAssertNil(app.localModelAPIKeyError)
        XCTAssertNil(try keys.inner.getLocalModelAPIKey())
        XCTAssertEqual(app.manualAgentAPIKey, "management-token")
    }

    @MainActor
    func testLoopbackModelKeyRotationAndManagementIsolation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("manual-agent-http-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = InMemoryKeychainService()
        let app = engine(dir, keychain: keys)
        let management = app.localAPIToken
        XCTAssertEqual(app.manualAgentAPIKey, management)
        let upstream = LocalTestUpstreamServer()
        let upstreamPort = try upstream.start(port: 0)
        defer { upstream.stop() }
        let provider = ProviderConfig(name: "Mock", baseURL: "http://127.0.0.1:\(upstreamPort)")
        try app.upsertProvider(provider, apiKey: "upstream-key")
        app.upsertModel(ModelConfig(providerID: provider.id, modelID: "mock-fast-mini", capabilities: [.chat]))
        let port = try XCTUnwrap(LoopbackHTTPServer.findAvailablePort(startingFrom: 25_700))
        app.updateProxyPort(port)
        app.startProxy()
        defer { app.stopProxy() }
        XCTAssertTrue(app.proxyState.isRunning)
        XCTAssertEqual(app.manualAgentRootURL, "http://127.0.0.1:\(port)")

        func send(_ path: String, method: String = "GET", key: String?, anthropic: Bool = false,
                  body: [String: Any]? = nil, extraHeaders: [String: String] = [:]) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            if let key { request.setValue(anthropic ? key : "Bearer \(key)", forHTTPHeaderField: anthropic ? "x-api-key" : "Authorization") }
            for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (_, response) = try await URLSession.shared.data(for: request)
            return try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
        }
        func assertStatus(_ expected: Int, _ path: String, method: String = "GET", key: String?,
                          extraHeaders: [String: String] = [:], line: UInt = #line) async throws {
            let status = try await send(path, method: method, key: key, extraHeaders: extraHeaders)
            XCTAssertEqual(status, expected, "\(method) \(path)", line: line)
        }

        try app.setLocalModelAPIKey("first-key")
        app.setRecordRequestBody(true)
        let requests: [(String, [String: Any])] = [
            ("/v1/chat/completions", ["model": "auto", "messages": [["role": "user", "content": "first-key"]]]),
            ("/v1/responses", ["model": "auto", "input": "hello"]),
            ("/v1/messages", ["model": "auto", "max_tokens": 32, "messages": [["role": "user", "content": "hello"]]])
        ]
        let models = try await send("/v1/models", key: "first-key")
        XCTAssertEqual(models, 200)
        for (path, body) in requests {
            let status = try await send(path, method: "POST", key: "first-key", anthropic: path == "/v1/messages", body: body)
            XCTAssertEqual(status, 200, path)
        }
        XCTAssertFalse(app.callHistory.contains { $0.requestPreview?.contains("first-key") == true })
        XCTAssertTrue(app.callHistory.contains { $0.requestPreview?.contains("[REDACTED_KEY]") == true })
        try await assertStatus(401, "/api/local/status", key: "first-key")
        for path in ["/api/local/receipts", "/api/local/models-health", "/api/local/agents"] {
            try await assertStatus(401, path, key: "first-key")
        }
        for path in ["/api/local/strategy", "/api/local/discover-and-probe", "/api/local/tiers"] {
            try await assertStatus(401, path, method: "POST", key: "first-key")
        }
        try await assertStatus(200, "/api/local/status", key: management)
        try await assertStatus(401, "/v1/models", method: "POST", key: "first-key")
        try await assertStatus(401, "/v1/messages", key: "first-key")
        try await assertStatus(401, "/v1/models", method: "OPTIONS", key: "first-key")
        try await assertStatus(401, "/v1/embeddings", method: "POST", key: "first-key")
        try await assertStatus(401, "/v1/responses/", method: "POST", key: "first-key")
        try await assertStatus(403, "/v1/models", key: "first-key", extraHeaders: ["Origin": "https://evil.example"])
        try await assertStatus(403, "/v1/models", key: "first-key", extraHeaders: ["Host": "evil.example"])
        try await assertStatus(200, "/health", key: nil)

        try app.setLocalModelAPIKey("second-key")
        try await assertStatus(401, "/v1/models", key: "first-key")
        try await assertStatus(200, "/v1/models", key: "second-key")
        try await assertStatus(200, "/api/local/status", key: management)
        let reopened = engine(dir, keychain: keys)
        XCTAssertEqual(reopened.manualAgentAPIKey, "second-key")
        XCTAssertEqual(reopened.localAPIToken, management)
        try app.clearLocalModelAPIKey()
        try await assertStatus(401, "/v1/models", key: "second-key")
        try await assertStatus(200, "/v1/models", key: management)
        XCTAssertEqual(app.manualAgentAPIKey, management)
        try await app.persistence.flush()
        XCTAssertFalse(try String(contentsOf: app.persistence.configFileURL, encoding: .utf8).contains("second-key"))
    }
}
