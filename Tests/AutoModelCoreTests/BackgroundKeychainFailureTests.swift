import Foundation
import Security
import XCTest
@testable import AutoModelCore

private final class CountingFailingKeychain: KeychainServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true
    private var token = "existing-test-token"
    private var operations: [String] = []
    func recover() { lock.withLock { failing = false } }
    var providerOperations: [String] { lock.withLock { operations } }
    func setAPIKey(_ key: String, for providerID: UUID) throws { lock.withLock { operations.append("set") } }
    func getAPIKey(for providerID: UUID) throws -> String? { lock.withLock { operations.append("get") }; return nil }
    func deleteAPIKey(for providerID: UUID) throws { lock.withLock { operations.append("delete") } }
    func hasAPIKey(for providerID: UUID) -> Bool { lock.withLock { operations.append("has") }; return false }
    func setLocalAPIToken(_ value: String) throws { lock.withLock { token = value } }
    func getLocalAPIToken() throws -> String? {
        try lock.withLock {
            if failing { throw KeychainError.unexpectedStatus(errSecUserCanceled) }
            return token
        }
    }
    func setLocalModelAPIKey(_ key: String) throws {}
    func getLocalModelAPIKey() throws -> String? { nil }
    func deleteLocalModelAPIKey() throws {}
    func allKnownSecretValues() -> [String] { lock.withLock { operations.append("secrets") }; return [] }
    func clearAll() throws { lock.withLock { operations.append("clear") } }
}

private final class NoNetworkURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests = 0
    static func reset() { lock.withLock { requests = 0 } }
    static var count: Int { lock.withLock { requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

final class BackgroundKeychainFailureTests: XCTestCase {
    @MainActor
    func testStartupFailureStopsBackgroundWorkAndRecoveryDoesNotImmediatelyStartIt() async throws {
        guard ProcessInfo.processInfo.environment["AUTOROUTE_ISOLATED_TESTS"] == "1" else {
            throw XCTSkip("Run in the isolated, network-denying sandbox; launch discovery otherwise reads the real home directory.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoRouteBackgroundFailure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home")
        let store = LocalPersistenceStore(baseDirectoryURL: directory.appendingPathComponent("data"))
        let providers = (0..<2).map { ProviderConfig(name: "Test \($0)", baseURL: "https://example.invalid/v1") }
        try store.saveConfig(AppConfigBundle(providers: providers, proxySettings: ProxySettings(
            autoStartProxy: true, autoDiscoverAndProbeOnLaunch: true, periodicHealthCheckMinutes: 1
        )))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoNetworkURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        NoNetworkURLProtocol.reset()
        let keychain = CountingFailingKeychain()
        let engine = AutoModelEngine(
            persistence: store, keychain: keychain, upstreamClient: UpstreamClient(session: session),
            agentConfigService: AgentConfigService(homeDirectory: home, backupDirectory: directory.appendingPathComponent("backup")),
            autoStartProxyIfConfigured: true
        )
        defer { engine.stopBackgroundTasks(); engine.stopProxy() }

        XCTAssertFalse(engine.isLocalAPITokenPersistent)
        XCTAssertFalse(engine.proxyState.isRunning)
        engine.startProxy()
        XCTAssertFalse(engine.proxyState.isRunning)
        XCTAssertThrowsError(try engine.applyAgentIntegration(kind: .codex))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
        // Allow the launch task to run; the sandbox also denies all real network and real-home reads.
        try await Task.sleep(nanoseconds: 4_000_000_000)
        XCTAssertEqual(keychain.providerOperations, [])
        XCTAssertEqual(NoNetworkURLProtocol.count, 0)
        XCTAssertNil(engine.lastDiscoverySummary)
        XCTAssertFalse(engine.isDiscoveringAndProbing)

        keychain.recover()
        try engine.retryPersistingLocalAPIToken()
        XCTAssertTrue(engine.isLocalAPITokenPersistent)
        XCTAssertEqual(engine.localAPIToken, "existing-test-token")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(keychain.providerOperations, [])
        XCTAssertEqual(NoNetworkURLProtocol.count, 0)
        XCTAssertNil(engine.lastDiscoverySummary)
        _ = try engine.applyAgentIntegration(kind: .codex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
    }

    @MainActor
    func testPeriodicHealthWaitsForRecoveryAndThenFullInterval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoRoutePeriodicFailure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPersistenceStore(baseDirectoryURL: directory.appendingPathComponent("data"))
        let provider = ProviderConfig(name: "Test", baseURL: "https://example.invalid/v1")
        try store.saveConfig(AppConfigBundle(providers: [provider], proxySettings: ProxySettings(
            autoStartProxy: false, autoDiscoverAndProbeOnLaunch: false, periodicHealthCheckMinutes: 1
        )))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoNetworkURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        NoNetworkURLProtocol.reset()
        let keychain = CountingFailingKeychain()
        let engine = AutoModelEngine(
            persistence: store, keychain: keychain, upstreamClient: UpstreamClient(session: session),
            agentConfigService: AgentConfigService(homeDirectory: directory.appendingPathComponent("home"), backupDirectory: directory.appendingPathComponent("backup")),
            autoStartProxyIfConfigured: true
        )
        defer { engine.stopBackgroundTasks(); engine.stopProxy() }
        try await Task.sleep(nanoseconds: 61_000_000_000)
        XCTAssertEqual(keychain.providerOperations, [])
        XCTAssertEqual(NoNetworkURLProtocol.count, 0)
        keychain.recover()
        try engine.retryPersistingLocalAPIToken()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(keychain.providerOperations, [])
        XCTAssertEqual(NoNetworkURLProtocol.count, 0)
        // Once the full interval passes, unknown credentials are still skipped.
        try await Task.sleep(nanoseconds: 62_000_000_000)
        XCTAssertNotNil(engine.lastDiscoverySummary)
        XCTAssertEqual(NoNetworkURLProtocol.count, 0)
        XCTAssertFalse(keychain.providerOperations.contains("get"))
    }

    @MainActor
    func testSuccessfulInitialTokenStillRunsLaunchDiscovery() async throws {
        guard ProcessInfo.processInfo.environment["AUTOROUTE_ISOLATED_TESTS"] == "1" else {
            throw XCTSkip("Run in the isolated, network-denying sandbox.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoRouteSuccessfulStartup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPersistenceStore(baseDirectoryURL: directory.appendingPathComponent("data"))
        let provider = ProviderConfig(name: "Test", baseURL: "https://example.invalid/v1")
        try store.saveConfig(AppConfigBundle(providers: [provider], proxySettings: ProxySettings(
            autoStartProxy: false, autoDiscoverAndProbeOnLaunch: true, periodicHealthCheckMinutes: 1
        )))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoNetworkURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        NoNetworkURLProtocol.reset()
        let keychain = CountingFailingKeychain()
        keychain.recover()
        let engine = AutoModelEngine(persistence: store, keychain: keychain, upstreamClient: UpstreamClient(session: session),
            agentConfigService: AgentConfigService(homeDirectory: directory.appendingPathComponent("home"), backupDirectory: directory.appendingPathComponent("backup")))
        defer { engine.stopBackgroundTasks(); engine.stopProxy() }
        for _ in 0..<30 where engine.lastDiscoverySummary == nil {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertNotNil(engine.lastDiscoverySummary)
        XCTAssertEqual(NoNetworkURLProtocol.count, 0)
        XCTAssertFalse(keychain.providerOperations.contains("get"))
    }

    @MainActor
    func testImmediateRecoveryBeforeLaunchTaskDoesNotTriggerDiscovery() async throws {
        guard ProcessInfo.processInfo.environment["AUTOROUTE_ISOLATED_TESTS"] == "1" else {
            throw XCTSkip("Run in the isolated, network-denying sandbox.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoRouteImmediateRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPersistenceStore(baseDirectoryURL: directory.appendingPathComponent("data"))
        try store.saveConfig(AppConfigBundle(proxySettings: ProxySettings(autoStartProxy: false, autoDiscoverAndProbeOnLaunch: true)))
        let keychain = CountingFailingKeychain()
        let engine = AutoModelEngine(persistence: store, keychain: keychain,
            agentConfigService: AgentConfigService(homeDirectory: directory.appendingPathComponent("home"), backupDirectory: directory.appendingPathComponent("backup")))
        defer { engine.stopBackgroundTasks(); engine.stopProxy() }
        keychain.recover()
        try engine.retryPersistingLocalAPIToken()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(engine.isLocalAPITokenPersistent)
        XCTAssertEqual(keychain.providerOperations, [])
        XCTAssertNil(engine.lastDiscoverySummary)
        XCTAssertFalse(engine.isDiscoveringAndProbing)
    }
}
