import XCTest

final class P2DocumentationTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testRequiredBilingualIntegrationAndCommunityDocumentsExist() throws {
        let required = [
            "README.md", "README.zh-CN.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md",
            "SECURITY.md", "ROADMAP.md", "CHANGELOG.md",
            "docs/demo/60-second-demo.md",
            "docs/integrations/codex.md", "docs/integrations/claude-code.md", "docs/integrations/opencode.md",
            "docs/release/RELEASE_CHECKLIST.md", "docs/community/GOOD_FIRST_ISSUES.md",
            ".github/PULL_REQUEST_TEMPLATE.md",
            ".github/ISSUE_TEMPLATE/bug_report.yml",
            ".github/ISSUE_TEMPLATE/feature_request.yml",
            ".github/ISSUE_TEMPLATE/integration_compatibility.yml"
        ]
        for path in required {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), "missing \(path)")
        }
    }

    func testQuickstartsUseCurrentAuthenticationAliasesAndHonestDemoLinks() throws {
        let english = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let chinese = try String(contentsOf: root.appendingPathComponent("README.zh-CN.md"), encoding: .utf8)
        for text in [english, chinese] {
            XCTAssertTrue(text.contains("AUTOROUTE_API_TOKEN"))
            XCTAssertTrue(text.contains("auto/agent/codex"))
            XCTAssertTrue(text.contains("dist/AutoRoute.app"))
            XCTAssertTrue(text.contains("README.zh-CN.md") || text.contains("README.md"))
            XCTAssertFalse(text.lowercased().contains("any non-empty"))
            XCTAssertFalse(text.contains("任意非空"))
        }
        XCTAssertTrue(english.contains("## 60-second demo") || english.contains("## 60-Second Demo"))
        XCTAssertTrue(english.contains("README.zh-CN.md"))
        XCTAssertTrue(chinese.contains("README.md"))

        for name in ["codex.md", "claude-code.md", "opencode.md"] {
            let guide = try String(contentsOf: root.appendingPathComponent("docs/integrations/\(name)"), encoding: .utf8)
            for required in ["恢复", "401", "端口", "预算", "token"] {
                XCTAssertTrue(guide.contains(required), "\(name) missing \(required)")
            }
        }

        let demo = try String(contentsOf: root.appendingPathComponent("docs/demo/60-second-demo.md"), encoding: .utf8)
        XCTAssertTrue(demo.contains("发现"))
        XCTAssertTrue(demo.contains("回退"))
        XCTAssertTrue(demo.contains("public-text-v1"))
        if let range = demo.range(of: #"\]\(([^)]+\.(gif|mp4|png))\)"#, options: .regularExpression) {
            let link = String(demo[range])
            XCTAssertFalse(link.contains("TODO"), "demo must not link a placeholder recording")
        }
    }

    func testRealUIScreenshotsAreLinkedWithDescriptiveAltText() throws {
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let names = [
            "onboarding.png", "routing-tiers.png", "agent-integration.png",
            "routing-receipt.png", "ab-report.png"
        ]
        for name in names {
            let imageURL = root.appendingPathComponent("docs/assets/\(name)")
            let data = try Data(contentsOf: imageURL)
            XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(name) is not a PNG")
            let imageLink = #"!\[[^\]]{8,}\]\(docs/assets/"# + name + #"\)"#
            XCTAssertNotNil(
                readme.range(of: imageLink, options: .regularExpression),
                "README must link \(name) with descriptive alt text"
            )
        }
    }

    func testReleaseChecklistKeepsExternalOperationsExplicit() throws {
        let checklist = try String(contentsOf: root.appendingPathComponent("docs/release/RELEASE_CHECKLIST.md"), encoding: .utf8)
        for required in ["DEVELOPER_ID_APPLICATION", "NOTARYTOOL_KEYCHAIN_PROFILE", "真实 A/B", "回滚", "description", "topics", "homepage", "分支保护"] {
            XCTAssertTrue(checklist.contains(required), "release checklist missing \(required)")
        }
        let roadmap = try String(contentsOf: root.appendingPathComponent("ROADMAP.md"), encoding: .utf8)
        XCTAssertTrue(roadmap.contains("DONE-BUT-UNVERIFIED"))
        XCTAssertTrue(roadmap.contains("非目标"))
    }
}
