import Foundation
import Security
import XCTest
@testable import AutoModelCore

private final class CredentialFake: KeychainServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [UUID: CachedAPIKey] = [:]
    private var stored: [UUID: String] = [:]
    private var failures: Set<UUID> = []
    private var writesFail = false
    private var log: [String] = []
    func seed(_ id: UUID, cached: CachedAPIKey, stored value: String? = nil, fails: Bool = false) {
        lock.withLock { cache[id] = cached; stored[id] = value; if fails { failures.insert(id) } }
    }
    func failWrites() { lock.withLock { writesFail = true } }
    var operations: [String] { lock.withLock { log } }
    func cachedAPIKey(for id: UUID) -> CachedAPIKey { lock.withLock { cache[id] ?? .unknown } }
    func getAPIKey(for id: UUID) throws -> String? {
        try lock.withLock {
            log.append("get:\(id)")
            if failures.contains(id) { throw KeychainError.unexpectedStatus(errSecUserCanceled) }
            let value = stored[id]
            cache[id] = value.map { .found($0) } ?? .missing
            return value
        }
    }
    func setAPIKey(_ key: String, for id: UUID) throws {
        try lock.withLock {
            log.append("set:\(id)")
            if writesFail { throw KeychainError.unexpectedStatus(errSecAuthFailed) }
            stored[id] = key; cache[id] = .found(key)
        }
    }
    func deleteAPIKey(for id: UUID) throws { lock.withLock { log.append("delete:\(id)"); stored[id] = nil; cache[id] = .missing } }
    func hasAPIKey(for id: UUID) -> Bool { fatalError("UI must not query keychain") }
    func setLocalAPIToken(_ token: String) throws {}
    func getLocalAPIToken() throws -> String? { "fixture-local-token" }
    func setLocalModelAPIKey(_ key: String) throws {}
    func getLocalModelAPIKey() throws -> String? { nil }
    func deleteLocalModelAPIKey() throws {}
    func allKnownSecretValues() -> [String] { [] }
    func clearAll() throws {}
}

private final class ProbeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var seen: [(String, String?)] = []
    static func reset() { lock.withLock { seen = [] } }
    static var requests: [(String, String?)] { lock.withLock { seen } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.seen.append((request.url!.host!, request.value(forHTTPHeaderField: "Authorization"))) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class BackgroundCredentialSafetyTests: XCTestCase {
    @MainActor
    private func makeEngine(_ dir: URL, keychain: CredentialFake, providers: [ProviderConfig], models: [ModelConfig]) throws -> AutoModelEngine {
        let store = LocalPersistenceStore(baseDirectoryURL: dir.appendingPathComponent("data"))
        try store.saveConfig(AppConfigBundle(providers: providers, models: models, proxySettings: ProxySettings(autoStartProxy: false, autoDiscoverAndProbeOnLaunch: false)))
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ProbeURLProtocol.self]
        return AutoModelEngine(persistence: store, keychain: keychain, upstreamClient: UpstreamClient(session: URLSession(configuration: sessionConfig)), agentConfigService: AgentConfigService(homeDirectory: dir.appendingPathComponent("home"), backupDirectory: dir.appendingPathComponent("backup")), autoStartProxyIfConfigured: false)
    }

    private func directory() throws -> URL {
        guard ProcessInfo.processInfo.environment["AUTOROUTE_ISOLATED_TESTS"] == "1" else { throw XCTSkip("Requires isolated home and network-denying sandbox") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("credential-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    func testCachedOnlyProbesFoundAndMissingButSkipsUnknownWithoutEviction() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let providers = ["unknown", "found", "missing"].map { ProviderConfig(name: $0, baseURL: "https://\($0).invalid/v1") }
        let models = providers.map { ModelConfig(providerID: $0.id, modelID: "model") }
        let keys = CredentialFake()
        keys.seed(providers[0].id, cached: .unknown, stored: "unread", fails: true)
        keys.seed(providers[1].id, cached: .found("known-key"), stored: "known-key")
        keys.seed(providers[2].id, cached: .missing)
        let engine = try makeEngine(dir, keychain: keys, providers: providers, models: models)
        ProbeURLProtocol.reset()
        XCTAssertEqual(engine.cachedAPIKey(for: providers[0].id), .unknown)
        XCTAssertFalse(engine.hasAPIKey(for: providers[0].id))
        _ = await engine.probeAllEnabledModels(credentialAccess: .cachedOnly)
        XCTAssertEqual(keys.operations, [])
        let requests = ProbeURLProtocol.requests
        XCTAssertEqual(Set(requests.map { $0.0 }), Set(["found.invalid", "missing.invalid"]))
        XCTAssertTrue(requests.contains { $0.0 == "found.invalid" && $0.1 == "Bearer known-key" })
        XCTAssertTrue(requests.contains { $0.0 == "missing.invalid" && $0.1 == nil })
        let skipped = try XCTUnwrap(engine.config.models.first { $0.id == models[0].id })
        XCTAssertFalse(skipped.isAutoEvicted)
        XCTAssertNil(skipped.lastProbedAt)
    }

    @MainActor
    func testExplicitReadFailureNeverProbesOrEvictsAndBlankEditPreservesKey() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ProviderConfig(name: "unknown", baseURL: "https://unknown.invalid/v1")
        let model = ModelConfig(providerID: provider.id, modelID: "model")
        let keys = CredentialFake(); keys.seed(provider.id, cached: .unknown, stored: "existing", fails: true)
        let engine = try makeEngine(dir, keychain: keys, providers: [provider], models: [model])
        ProbeURLProtocol.reset()
        try engine.upsertProvider(provider, apiKey: nil)
        XCTAssertEqual(keys.operations, [])
        _ = await engine.probeAllEnabledModels()
        await engine.probeSingleModel(modelID: model.id)
        _ = await engine.testProviderConnection(providerID: provider.id)
        XCTAssertEqual(keys.operations.filter { $0.hasPrefix("get:") }.count, 3)
        XCTAssertTrue(ProbeURLProtocol.requests.isEmpty)
        XCTAssertFalse(try XCTUnwrap(engine.config.models.first).isAutoEvicted)
        XCTAssertEqual(engine.cachedAPIKey(for: provider.id), .unknown)
    }

    @MainActor
    func testExplicitReadAuthorizesCacheForSubsequentBackgroundProbe() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ProviderConfig(name: "found", baseURL: "https://found.invalid/v1")
        let model = ModelConfig(providerID: provider.id, modelID: "model")
        let keys = CredentialFake(); keys.seed(provider.id, cached: .unknown, stored: "authorized-key")
        let engine = try makeEngine(dir, keychain: keys, providers: [provider], models: [model])
        XCTAssertEqual(engine.apiKeyForProvider(provider.id), "authorized-key")
        XCTAssertEqual(engine.cachedAPIKey(for: provider.id), .found("authorized-key"))
        ProbeURLProtocol.reset()
        _ = await engine.probeAllEnabledModels(credentialAccess: .cachedOnly)
        XCTAssertEqual(keys.operations, ["get:\(provider.id)"])
        XCTAssertTrue(ProbeURLProtocol.requests.contains { $0.0 == "found.invalid" && $0.1 == "Bearer authorized-key" })
    }

    func testFreshMacKeychainCacheReportsUnknownWithoutSecurityRead() throws {
        _ = try directory()
        let keychain = MacOSKeychainService(service: "fake.never-accessed.\(UUID())")
        let id = UUID()
        XCTAssertEqual(keychain.cachedAPIKey(for: id), .unknown)
        XCTAssertFalse(keychain.hasAPIKey(for: id))
    }

    @MainActor
    func testBackgroundDiscoveryDoesNotImportAndExplicitFailedReadDoesNotOverwrite() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ProviderConfig(name: "existing", baseURL: "https://existing.invalid/v1")
        let model = ModelConfig(providerID: provider.id, modelID: "model")
        let keys = CredentialFake(); keys.seed(provider.id, cached: .unknown, stored: "existing", fails: true)
        let engine = try makeEngine(dir, keychain: keys, providers: [provider], models: [model])
        let home = dir.appendingPathComponent("home")
        let configDir = home.appendingPathComponent(".config/opencode")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let fixture: [String: Any] = ["provider": ["existing": ["options": ["baseURL": provider.baseURL, "apiKey": "discovered"], "models": [:]], "new": ["options": ["baseURL": "https://new.invalid/v1", "apiKey": "new-key"], "models": [:]]]]
        try JSONSerialization.data(withJSONObject: fixture).write(to: configDir.appendingPathComponent("opencode.json"))
        ProbeURLProtocol.reset()
        _ = await engine.discoverAndProbeLocalModels(homeDirectory: home, scanWellKnownLocalPorts: false, credentialAccess: .cachedOnly)
        XCTAssertEqual(keys.operations, [])
        XCTAssertTrue(ProbeURLProtocol.requests.isEmpty)
        XCTAssertFalse(try XCTUnwrap(engine.config.models.first { $0.id == model.id }).isAutoEvicted)
        XCTAssertNotNil(engine.config.providers.first { $0.baseURL == "https://new.invalid/v1" })
        _ = await engine.discoverAndProbeLocalModels(homeDirectory: home, scanWellKnownLocalPorts: false)
        XCTAssertFalse(keys.operations.contains("set:\(provider.id)"))
        XCTAssertFalse(ProbeURLProtocol.requests.contains { $0.0 == "existing.invalid" })
        XCTAssertFalse(try XCTUnwrap(engine.config.models.first { $0.id == model.id }).isAutoEvicted)
    }

    @MainActor
    func testExplicitImportWriteFailureDoesNotProbeOrEvict() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ProviderConfig(name: "existing", baseURL: "https://existing.invalid/v1")
        let model = ModelConfig(providerID: provider.id, modelID: "model")
        let keys = CredentialFake(); keys.seed(provider.id, cached: .missing); keys.failWrites()
        let engine = try makeEngine(dir, keychain: keys, providers: [provider], models: [model])
        let home = dir.appendingPathComponent("home"), configDir = home.appendingPathComponent(".config/opencode")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let fixture: [String: Any] = ["provider": ["existing": ["options": ["baseURL": provider.baseURL, "apiKey": "discovered"], "models": [:]]]]
        try JSONSerialization.data(withJSONObject: fixture).write(to: configDir.appendingPathComponent("opencode.json"))
        ProbeURLProtocol.reset()
        _ = await engine.discoverAndProbeLocalModels(homeDirectory: home, scanWellKnownLocalPorts: false)
        XCTAssertTrue(keys.operations.contains("set:\(provider.id)"))
        XCTAssertTrue(ProbeURLProtocol.requests.isEmpty)
        XCTAssertFalse(try XCTUnwrap(engine.config.models.first).isAutoEvicted)
    }
}
