import Foundation
import XCTest
@testable import AutoModelCore

final class PersistenceLifecycleTests: XCTestCase {
    @MainActor
    func testQueueIsOffMainActorAndShutdownDrainsOutstandingRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoRouteDrain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "test.persistence.drain")
        let store = LocalPersistenceStore(baseDirectoryURL: directory, queue: queue)
        let engine = AutoModelEngine(persistence: store, keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        try await store.flush()
        let entered = expectation(description: "disk queue blocked")
        let gate = DispatchSemaphore(value: 0)
        queue.async {
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
        }
        await fulfillment(of: [entered], timeout: 2)
        var completed = false
        let request = Task { @MainActor in
            _ = await engine.executeChatCompletion(payload: [
                "model": "missing-model", "messages": [["role": "user", "content": "fixture"]]
            ], source: .testBench)
            completed = true
        }
        // MainActor remains schedulable while durable completion waits on the serial queue.
        for _ in 0..<100 where engine.callHistory.isEmpty { await Task.yield() }
        XCTAssertEqual(engine.callHistory.count, 1)
        XCTAssertTrue(completed, "Request receipt must not wait for disk I/O")
        let shutdown = Task { @MainActor in try await engine.shutdown() }
        await Task.yield()
        gate.signal()
        await request.value
        try await shutdown.value
        XCTAssertTrue(completed)
        XCTAssertEqual(store.loadHistory().map(\.id), engine.callHistory.map(\.id))
    }

    @MainActor
    func testConcurrentBurstKeepsSnapshotOrderAndClearCannotResurrectHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoRouteBurst-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPersistenceStore(baseDirectoryURL: directory)
        let engine = AutoModelEngine(persistence: store, keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        let tasks = (0..<30).map { index in
            Task { @MainActor in
                await engine.executeChatCompletion(payload: [
                    "model": "missing-\(index)", "messages": [["role": "user", "content": "fixture"]]
                ], source: .testBench)
            }
        }
        for task in tasks { _ = await task.value }
        try await store.flush()
        XCTAssertEqual(engine.callHistory.count, 30)
        XCTAssertEqual(store.loadHistory().map(\.id), engine.callHistory.map(\.id))
        try engine.clearCallHistory()
        try await engine.shutdown()
        XCTAssertTrue(store.loadHistory().isEmpty)
        XCTAssertEqual(store.loadBudgetLedger()?.usage(agentID: nil).totalCostUSD ?? 0, 0)
    }

    @MainActor
    func testBilledUsageIsDurableAfterFlushAndShutdownFailureCanRecover() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoRouteDurableBudget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = LoopbackHTTPServer { _, writer in
            writer.sendJSON(statusCode: 200, body: Data("{\"choices\":[{\"message\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":20}}".utf8))
        }
        let port = try upstream.start(port: 0)
        defer { upstream.stop() }
        let store = LocalPersistenceStore(baseDirectoryURL: directory)
        let engine = AutoModelEngine(persistence: store, keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        let provider = ProviderConfig(name: "durability fixture", baseURL: "http://127.0.0.1:\(port)", healthStatus: .healthy)
        try engine.upsertProvider(provider, apiKey: nil)
        let model = ModelConfig(providerID: provider.id, modelID: "priced-fixture", inputPricePerMillion: 1_000, outputPricePerMillion: 1_000, capabilities: [.chat], availabilityStatus: .available)
        engine.upsertModel(model)
        let outcome = await engine.executeChatCompletion(payload: [
            "model": model.modelID, "messages": [["role": "user", "content": "fixture"]]
        ], source: .testBench)
        XCTAssertEqual(outcome.httpStatusCode, 200)
        try await store.flush()
        XCTAssertEqual(engine.monthlyBudgetUsage().totalCostUSD, 0.12, accuracy: 0.0001)
        // Reopen a separate store, not a queue barrier on the original store.
        let reopened = LocalPersistenceStore(baseDirectoryURL: directory)
        XCTAssertEqual(try XCTUnwrap(reopened.loadBudgetLedger()).usage(agentID: nil).totalCostUSD, 0.12, accuracy: 0.0001)
        try FileManager.default.removeItem(at: store.budgetLedgerFileURL)
        try FileManager.default.createDirectory(at: store.budgetLedgerFileURL, withIntermediateDirectories: true)
        await engine.persistCallHistory()
        do { try await engine.shutdown(); XCTFail("must reject unsafe shutdown") } catch {}
        XCTAssertNotNil(engine.lastPersistenceError)
        XCTAssertEqual(engine.monthlyBudgetUsage().totalCostUSD, 0.12, accuracy: 0.0001)
        try FileManager.default.removeItem(at: store.budgetLedgerFileURL)
        await engine.persistCallHistory()
        try await engine.shutdown()
        XCTAssertEqual(try XCTUnwrap(reopened.loadBudgetLedger()).usage(agentID: nil).totalCostUSD, 0.12, accuracy: 0.0001)
    }

    @MainActor
    func testConfigWriteCannotHideFailedHistorySnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoRouteErrorTracking-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPersistenceStore(baseDirectoryURL: directory)
        let engine = AutoModelEngine(persistence: store, keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        try await store.flush()
        try FileManager.default.createDirectory(at: store.historyFileURL, withIntermediateDirectories: true)
        await engine.persistCallHistory()
        do { try await store.flush(); XCTFail("snapshot should fail") } catch {}
        engine.saveConfig()
        do { try await store.flush(); XCTFail("config success must not clear a failed history snapshot") } catch {}
        try FileManager.default.removeItem(at: store.historyFileURL)
        await engine.persistCallHistory()
        try await store.flush()
    }

    @MainActor
    func testFailedShutdownKeepsRunningServersAvailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoRouteShutdownRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPersistenceStore(baseDirectoryURL: directory)
        let engine = AutoModelEngine(persistence: store, keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        engine.updateProxyPort(0)
        engine.startProxy()
        XCTAssertTrue(engine.proxyState.isRunning)
        _ = try engine.startLocalTestUpstream(port: 0)
        try await store.flush()
        try FileManager.default.createDirectory(at: store.historyFileURL, withIntermediateDirectories: true)
        await engine.persistCallHistory()
        do { try await engine.shutdown(); XCTFail("shutdown should fail") } catch {}
        XCTAssertTrue(engine.proxyState.isRunning, "proxy must remain usable when shutdown is cancelled")
        XCTAssertTrue(engine.isLocalTestUpstreamRunning, "test server must remain usable when shutdown is cancelled")
        try FileManager.default.removeItem(at: store.historyFileURL)
        await engine.persistCallHistory()
        try await engine.shutdown()
        XCTAssertFalse(engine.proxyState.isRunning)
        XCTAssertFalse(engine.isLocalTestUpstreamRunning)
    }

    @MainActor
    func testHistoryWriteFailureIsVisible() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoRoutePersistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPersistenceStore(baseDirectoryURL: directory)
        let engine = AutoModelEngine(persistence: store, keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        // A directory at the destination deterministically rejects atomic file replacement.
        try FileManager.default.createDirectory(at: store.historyFileURL, withIntermediateDirectories: true)
        _ = await engine.executeChatCompletion(payload: [
            "model": "missing-model", "messages": [["role": "user", "content": "fixture"]]
        ], source: .testBench)
        do { try await store.flush(); XCTFail("flush must expose the failed write") } catch {}
        await Task.yield()
        XCTAssertNotNil(engine.lastPersistenceError, "History errors must not be silently discarded")
    }
}
