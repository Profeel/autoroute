import Foundation
import XCTest
@testable import AutoModelCore

final class P1AgentRecoveryTests: XCTestCase {
    private let token = "agent-recovery-local-token"

    private func service() -> (AgentConfigService, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRouteAgentRecovery-\(UUID().uuidString)", isDirectory: true)
        return (AgentConfigService(homeDirectory: home, backupDirectory: home.appendingPathComponent("_backups")), home)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeJSON(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func apply(_ service: AgentConfigService, _ kind: AgentKind) throws {
        _ = try service.applyAgentConfig(
            kind: kind,
            binding: AgentModelBinding(),
            proxyPort: 28765,
            localAPIToken: token
        )
    }

    func testCorruptManifestNeverOverwritesExistingOriginalBackup() throws {
        let (service, home) = service()
        defer { try? FileManager.default.removeItem(at: home) }
        let configURL = service.primaryConfigURL(for: .opencode)
        try writeJSON(["model": "external/model", "provider": ["external": ["name": "External"]]], to: configURL)
        try apply(service, .opencode)

        let backupURL = home.appendingPathComponent("_backups/opencode.bak")
        let originalBackup = try Data(contentsOf: backupURL)
        let manifestURL = home.appendingPathComponent("_backups/manifest.json")
        try Data("{not-valid-json".utf8).write(to: manifestURL)
        XCTAssertTrue(service.inspectAgent(.opencode, proxyPort: 28765).hasBackup, "UI must not hide an existing backup when the manifest is corrupt")

        XCTAssertThrowsError(try apply(service, .opencode)) { error in
            XCTAssertTrue(error.localizedDescription.contains("备份清单"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: backupURL), originalBackup)

        XCTAssertThrowsError(try service.restoreAgentConfig(kind: .opencode, proxyPort: 28765)) { error in
            XCTAssertTrue(error.localizedDescription.contains("备份清单"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("尚无备份记录"))
        }
        XCTAssertEqual(try Data(contentsOf: backupURL), originalBackup)
    }

    func testOpenCodeRestoreKeepsExternalProvidersAndRestoresOriginalPointersAcrossRepeatedCycles() throws {
        let (service, home) = service()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = service.primaryConfigURL(for: .opencode)
        let original: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "model": "external/first",
            "small_model": "external/first-small",
            "theme": "original-theme",
            "provider": [
                "external": ["name": "External", "options": ["baseURL": "https://external.example"]],
                "mcp-server": ["type": "remote"]
            ]
        ]
        try writeJSON(original, to: url)

        for _ in 0..<2 {
            try apply(service, .opencode)
            var afterApply = try readJSON(url)
            var providers = try XCTUnwrap(afterApply["provider"] as? [String: Any])
            providers["external-late"] = ["name": "Added After Injection"]
            afterApply["provider"] = providers
            afterApply["theme"] = "post-injection-theme"
            try writeJSON(afterApply, to: url)

            _ = try service.restoreAgentConfig(kind: .opencode, proxyPort: 28765)
            let restored = try readJSON(url)
            let restoredProviders = try XCTUnwrap(restored["provider"] as? [String: Any])
            XCTAssertNil(restoredProviders["automodel"])
            XCTAssertNotNil(restoredProviders["external"])
            XCTAssertNotNil(restoredProviders["external-late"])
            XCTAssertNotNil(restoredProviders["mcp-server"])
            XCTAssertEqual(restored["model"] as? String, "external/first")
            XCTAssertEqual(restored["small_model"] as? String, "external/first-small")
            XCTAssertEqual(restored["theme"] as? String, "post-injection-theme")
            XCTAssertFalse(service.inspectAgent(.opencode, proxyPort: 28765).hasBackup)
        }
    }

    func testOpenCodeRestoreWhenOriginalMissingRemovesManagedEntriesButKeepsLaterExternalProvider() throws {
        let (service, home) = service()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = service.primaryConfigURL(for: .opencode)
        try apply(service, .opencode)
        var integrated = try readJSON(url)
        var providers = try XCTUnwrap(integrated["provider"] as? [String: Any])
        providers["external-late"] = ["name": "Late External"]
        integrated["provider"] = providers
        try writeJSON(integrated, to: url)

        _ = try service.restoreAgentConfig(kind: .opencode, proxyPort: 28765)
        let restored = try readJSON(url)
        let restoredProviders = try XCTUnwrap(restored["provider"] as? [String: Any])
        XCTAssertNil(restoredProviders["automodel"])
        XCTAssertNotNil(restoredProviders["external-late"])
        XCTAssertNil(restored["model"])
        XCTAssertNil(restored["small_model"])
    }

    func testContinueRestoreRemovesOnlyAutoRouteModelsAndPreservesExternalModelsAndSettings() throws {
        let (service, home) = service()
        defer { try? FileManager.default.removeItem(at: home) }
        let continueURL = home.appendingPathComponent(".continue/config.json")
        try writeJSON([
            "models": [["title": "User Model", "provider": "openai", "model": "user-model"]],
            "contextProviders": [["name": "user-context"]],
            "allowAnonymousTelemetry": false
        ], to: continueURL)

        for _ in 0..<2 {
            try apply(service, .shellAndContinue)
            var current = try readJSON(continueURL)
            var models = try XCTUnwrap(current["models"] as? [[String: Any]])
            models.append(["title": "User Added", "provider": "openai", "model": "user-added"])
            current["models"] = models
            current["theme"] = "external-theme"
            try writeJSON(current, to: continueURL)

            _ = try service.restoreAgentConfig(kind: .shellAndContinue, proxyPort: 28765)
            let restored = try readJSON(continueURL)
            let titles = try XCTUnwrap(restored["models"] as? [[String: Any]])
                .compactMap { $0["title"] as? String }
            XCTAssertFalse(titles.contains { $0.hasPrefix("AutoRoute") || $0.hasPrefix("Auto Model") })
            XCTAssertTrue(titles.contains("User Model"))
            XCTAssertTrue(titles.contains("User Added"))
            XCTAssertEqual((restored["contextProviders"] as? [[String: Any]])?.first?["name"] as? String, "user-context")
            XCTAssertEqual(restored["allowAnonymousTelemetry"] as? Bool, false)
            XCTAssertEqual(restored["theme"] as? String, "external-theme")
        }
    }

    func testShellEnvRestoreWhenOriginalMissingKeepsUserAddedLines() throws {
        let (service, home) = service()
        defer { try? FileManager.default.removeItem(at: home) }
        let envURL = service.primaryConfigURL(for: .shellAndContinue)
        try apply(service, .shellAndContinue)
        let integrated = try String(contentsOf: envURL, encoding: .utf8)
        try (integrated + "\nexport USER_ADDED_AFTER_INJECTION=1\n").write(to: envURL, atomically: true, encoding: .utf8)

        _ = try service.restoreAgentConfig(kind: .shellAndContinue, proxyPort: 28765)
        let restored = try String(contentsOf: envURL, encoding: .utf8)
        XCTAssertTrue(restored.contains("USER_ADDED_AFTER_INJECTION=1"))
        XCTAssertFalse(restored.contains(token))
        XCTAssertFalse(restored.contains("OPENAI_BASE_URL=\"http://127.0.0.1:28765/v1\""))
    }
}