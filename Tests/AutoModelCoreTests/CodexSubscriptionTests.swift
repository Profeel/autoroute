import XCTest
@testable import AutoModelCore

final class CodexSubscriptionTests: XCTestCase {

    private final class RequestCaptureBox: @unchecked Sendable {
        struct Captured {
            let path: String
            let authorization: String?
            let accountID: String?
            let originator: String?
            let bodyData: Data
        }

        private let lock = NSLock()
        private var items: [Captured] = []

        func append(_ req: HTTPRequestMessage) {
            lock.withLock {
                items.append(Captured(
                    path: req.path,
                    authorization: req.header("authorization"),
                    accountID: req.header("chatgpt-account-id"),
                    originator: req.header("originator"),
                    bodyData: req.body
                ))
            }
        }

        func snapshot() -> [Captured] {
            lock.withLock { items }
        }
    }

    private func makeTempDir(_ name: String = UUID().uuidString) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoModelCodexTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFakeJWT(
        email: String? = nil,
        accountID: String? = nil,
        planType: String? = nil,
        exp: TimeInterval? = nil
    ) -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        var payload: [String: Any] = [:]
        if let email { payload["email"] = email }
        if let exp { payload["exp"] = Int(exp) }
        var auth: [String: Any] = [:]
        if let accountID { auth["chatgpt_account_id"] = accountID }
        if let planType { auth["chatgpt_plan_type"] = planType }
        if !auth.isEmpty {
            payload["https://api.openai.com/auth"] = auth
        }
        let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return "\(header).\(base64URL(payloadData)).sig"
    }

    // MARK: - 1. JWT, Auth File Parsing & Codec Redaction

    func testJWTClaimsAuthFileAndCodecRedaction() throws {
        let futureExp = Date().addingTimeInterval(3600).timeIntervalSince1970
        let accessJWT = makeFakeJWT(accountID: "acct_jwt_1", planType: "plus", exp: futureExp)
        let idJWT = makeFakeJWT(email: "dev@example.com", accountID: "acct_jwt_1", planType: "pro", exp: futureExp)

        let claims = CodexJWTClaims.parse(idJWT)
        XCTAssertEqual(claims.email, "dev@example.com")
        XCTAssertEqual(claims.accountID, "acct_jwt_1")
        XCTAssertEqual(claims.planType, "pro")
        XCTAssertNotNil(claims.expiresAt)

        let dir = makeTempDir("authparse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let codexDir = dir.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let authJSON: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": accessJWT,
                "refresh_token": "rt_secret_abc_999",
                "id_token": idJWT,
                "account_id": "acct_explicit_1"
            ]
        ]
        let authURL = codexDir.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: authJSON).write(to: authURL)

        let parsed = try XCTUnwrap(CodexAuthFileParser.parseAuthFile(at: authURL))
        XCTAssertEqual(parsed.accessToken, accessJWT)
        XCTAssertEqual(parsed.refreshToken, "rt_secret_abc_999")
        XCTAssertEqual(parsed.accountID, "acct_explicit_1")
        XCTAssertEqual(parsed.email, "dev@example.com")
        XCTAssertEqual(parsed.planType, "pro")
        XCTAssertFalse(parsed.isExpiredOrExpiringSoon())

        // Keychain storage + SecretRedactor must redact both accessToken and refreshToken
        let pid = UUID()
        let keychain = InMemoryKeychainService()
        try keychain.setCodexAccounts([parsed], for: pid)
        let decoded = try keychain.getCodexAccounts(for: pid)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].refreshToken, "rt_secret_abc_999")
        XCTAssertEqual(try keychain.getAPIKeys(for: pid), [accessJWT])

        let secrets = keychain.allKnownSecretValues()
        let redacted = SecretRedactor.redact("err with \(accessJWT) and rt_secret_abc_999", secrets: secrets)
        XCTAssertFalse(redacted.contains(accessJWT))
        XCTAssertFalse(redacted.contains("rt_secret_abc_999"))
    }

    // MARK: - 2. Proactive & Reactive Token Refresh + Single-Flight Coalescing

    @MainActor
    func testProactiveAndReactiveCodexTokenRefreshAndCoalescing() async throws {
        let dir = makeTempDir("refresh")
        defer { try? FileManager.default.removeItem(at: dir) }

        final class OAuthMockState: @unchecked Sendable {
            private let lock = NSLock()
            var refreshCount = 0
            var receivedRefreshTokens: [String] = []
            func recordRefresh(rt: String) -> Int {
                lock.withLock {
                    refreshCount += 1
                    receivedRefreshTokens.append(rt)
                    return refreshCount
                }
            }
            func snapshotCount() -> Int { lock.withLock { refreshCount } }
            func snapshotTokens() -> [String] { lock.withLock { receivedRefreshTokens } }
        }

        let oauthState = OAuthMockState()
        let futureExp = Date().addingTimeInterval(3600).timeIntervalSince1970
        let freshAccess1 = makeFakeJWT(email: "user1@example.com", accountID: "acct_1", planType: "plus", exp: futureExp)
        let freshAccess2 = makeFakeJWT(email: "user1@example.com", accountID: "acct_1", planType: "plus", exp: futureExp + 3600)

        let oauthServer = LoopbackHTTPServer { req, writer in
            let bodyStr = String(data: req.body, encoding: .utf8) ?? ""
            var params: [String: String] = [:]
            for pair in bodyStr.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    params[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
                }
            }
            let rt = params["refresh_token"] ?? ""
            let n = oauthState.recordRefresh(rt: rt)
            // Small delay to verify concurrent requests coalesce on single refresh task
            try? await Task.sleep(nanoseconds: 50_000_000)
            let tokenToReturn = (n == 1) ? freshAccess1 : freshAccess2
            let respObj: [String: Any] = [
                "access_token": tokenToReturn,
                "refresh_token": "rt_rotated_\(n + 1)",
                "expires_in": 3600
            ]
            let data = (try? JSONSerialization.data(withJSONObject: respObj)) ?? Data()
            writer.sendJSON(statusCode: 200, body: data)
        }
        let oauthPort = try oauthServer.start(port: 0)
        defer { oauthServer.stop() }

        let upstreamCapture = RequestCaptureBox()
        let upstreamServer = LoopbackHTTPServer { req, writer in
            upstreamCapture.append(req)
            let auth = req.header("authorization") ?? ""
            // Reject freshAccess1 with 401 once to test reactive 401 refresh -> freshAccess2
            if auth == "Bearer \(freshAccess1)" {
                writer.sendJSON(statusCode: 401, body: Data(#"{"error":{"message":"Token expired"}}"#.utf8))
                return
            }
            let sse = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok-codex\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":5,\"output_tokens\":2}}}\n\n"
            writer.startChunkedStream()
            _ = writer.writeStreamChunk(Data(sse.utf8))
            writer.finishStream()
        }
        let upstreamPort = try upstreamServer.start(port: 0)
        defer { upstreamServer.stop() }

        let oauthConfig = CodexOAuthConfiguration(
            clientID: "test-client",
            authorizeEndpoint: URL(string: "http://127.0.0.1:\(oauthPort)/oauth/authorize")!,
            tokenEndpoint: URL(string: "http://127.0.0.1:\(oauthPort)/oauth/token")!,
            redirectURI: "http://localhost:1455/auth/callback",
            callbackPort: 1455
        )
        let keychain = InMemoryKeychainService()
        let engine = AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: dir),
            keychain: keychain,
            alertNotifier: NoOpSystemAlertNotifier(),
            codexOAuthClient: CodexOAuthClient(configuration: oauthConfig),
            codexHomeDirectory: dir,
            autoStartProxyIfConfigured: false
        )

        let expiredAccount = CodexSubscriptionAccount(
            label: "user1@example.com",
            email: "user1@example.com",
            planType: "plus",
            accountID: "acct_1",
            accessToken: "expired_access_0",
            refreshToken: "rt_initial_1",
            expiresAt: Date().addingTimeInterval(-60),
            source: "oauth_login"
        )
        let added = try engine.addCodexSubscriptionAccount(expiredAccount, modelSlugs: ["gpt-5.4"])
        // Point provider to our mock Codex server
        var p = added.provider
        p.baseURL = "http://127.0.0.1:\(upstreamPort)"
        try engine.upsertProvider(p, apiKeys: nil)

        // Concurrent calls should coalesce proactive refresh onto 1 OAuth call -> freshAccess1 -> upstream 401 -> reactive refresh -> freshAccess2
        let outcome = await engine.executeChatCompletion(
            payload: [
                "model": "gpt-5.4",
                "messages": [["role": "user", "content": "hello"]],
                "stream": false
            ],
            source: .testBench
        )
        XCTAssertEqual(outcome.httpStatusCode, 200)
        let bodyStr = String(data: outcome.responseBody, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("ok-codex"))

        // OAuth refresh called twice (proactive with rt_initial_1 -> rt_rotated_2, reactive 401 with rt_rotated_2 -> rt_rotated_3)
        XCTAssertEqual(oauthState.snapshotTokens(), ["rt_initial_1", "rt_rotated_2"])
        let storedAccounts = try keychain.getCodexAccounts(for: p.id)
        XCTAssertEqual(storedAccounts.first?.accessToken, freshAccess2)
        XCTAssertEqual(storedAccounts.first?.refreshToken, "rt_rotated_3")

        // Verify coordinator coalesces 4 concurrent refresh calls on same account ID
        let coordinator = CodexTokenRefreshCoordinator()
        let client = CodexOAuthClient(configuration: oauthConfig)
        let countBefore = oauthState.snapshotCount()
        let acctToRefresh = storedAccounts[0]
        try await withThrowingTaskGroup(of: CodexSubscriptionAccount.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await coordinator.refresh(account: acctToRefresh, using: client)
                }
            }
            for try await _ in group {}
        }
        XCTAssertEqual(oauthState.snapshotCount() - countBefore, 1, "Concurrent refreshes must coalesce into 1 HTTP call")
    }

    // MARK: - 3. Multi-Account Codex Subscription Pool Failover (429 Usage Limit)

    @MainActor
    func testMultiAccountCodexSubscriptionFailoverOn429() async throws {
        let dir = makeTempDir("multipool")
        defer { try? FileManager.default.removeItem(at: dir) }

        let capture = RequestCaptureBox()
        let upstreamServer = LoopbackHTTPServer { req, writer in
            capture.append(req)
            let auth = req.header("authorization") ?? ""
            if auth == "Bearer token_acct_alpha" {
                let err = Data(#"{"error":{"message":"You have hit your ChatGPT Plus usage limit. Subscribe to Pro to continue.","type":"usage_limit_reached"}}"#.utf8)
                writer.sendJSON(statusCode: 429, headers: ["Retry-After": "120"], body: err)
                return
            }
            let sse = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"served-by-beta\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r_beta\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":6,\"output_tokens\":3}}}\n\n"
            writer.startChunkedStream()
            _ = writer.writeStreamChunk(Data(sse.utf8))
            writer.finishStream()
        }
        let upstreamPort = try upstreamServer.start(port: 0)
        defer { upstreamServer.stop() }

        let keychain = InMemoryKeychainService()
        let engine = AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: dir),
            keychain: keychain,
            alertNotifier: NoOpSystemAlertNotifier(),
            autoStartProxyIfConfigured: false
        )

        let alpha = CodexSubscriptionAccount(
            label: "alpha@example.com",
            email: "alpha@example.com",
            planType: "plus",
            accountID: "acct_alpha",
            accessToken: "token_acct_alpha",
            expiresAt: Date().addingTimeInterval(3600),
            source: "oauth_login"
        )
        let beta = CodexSubscriptionAccount(
            label: "beta@example.com",
            email: "beta@example.com",
            planType: "pro",
            accountID: "acct_beta",
            accessToken: "token_acct_beta",
            expiresAt: Date().addingTimeInterval(3600),
            source: "oauth_login"
        )
        let res = try engine.addCodexSubscriptionAccount(alpha, modelSlugs: ["gpt-5.4", "gpt-5.3-codex"])
        _ = try engine.addCodexSubscriptionAccount(beta)
        var codexProvider = res.provider
        codexProvider.baseURL = "http://127.0.0.1:\(upstreamPort)"
        codexProvider.keyRotationStrategy = .priorityFailover
        try engine.upsertProvider(codexProvider, apiKeys: nil)

        // Direct model selection (not auto) should STILL failover across subscription accounts!
        let outcome1 = await engine.executeChatCompletion(
            payload: [
                "model": "gpt-5.4",
                "messages": [["role": "user", "content": "write code"]],
                "stream": false
            ],
            source: .externalProxy
        )
        XCTAssertEqual(outcome1.httpStatusCode, 200)
        XCTAssertTrue(String(data: outcome1.responseBody, encoding: .utf8)?.contains("served-by-beta") == true)
        XCTAssertEqual(outcome1.callRecord.attempts.count, 2)
        XCTAssertEqual(outcome1.callRecord.attempts[0].succeeded, false)
        XCTAssertEqual(outcome1.callRecord.attempts[0].accountLabel, "alpha@example.com (PLUS)")
        XCTAssertEqual(outcome1.callRecord.attempts[1].succeeded, true)
        XCTAssertEqual(outcome1.callRecord.attempts[1].accountLabel, "beta@example.com (PRO)")

        let requests = capture.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].accountID, "acct_alpha")
        XCTAssertEqual(requests[1].accountID, "acct_beta")

        // Second request skips cooled alpha and hits beta directly
        let outcome2 = await engine.executeChatCompletion(
            payload: [
                "model": "gpt-5.4",
                "messages": [["role": "user", "content": "next turn"]],
                "stream": false
            ],
            source: .externalProxy
        )
        XCTAssertEqual(outcome2.httpStatusCode, 200)
        XCTAssertEqual(capture.snapshot().count, 3)
        XCTAssertEqual(capture.snapshot().last?.accountID, "acct_beta")
    }

    // MARK: - 4. Cross-Agent Borrowing: Claude Code (/v1/messages) -> Codex Subscription Base Model

    @MainActor
    func testClaudeCodeStreamingToolCallsAgainstCodexSubscriptionBaseModel() async throws {
        let dir = makeTempDir("claudetocodex")
        defer { try? FileManager.default.removeItem(at: dir) }

        let capture = RequestCaptureBox()
        let codexMock = LoopbackHTTPServer { req, writer in
            capture.append(req)
            let events = [
                #"data: {"type":"response.reasoning_summary_text.delta","delta":"Checking repo..."}"#,
                #"data: {"type":"response.output_text.delta","delta":"Let me run a check."}"#,
                #"data: {"type":"response.output_item.added","item":{"id":"fc_1","type":"function_call","call_id":"call_bash_1","name":"bash"}}"#,
                #"data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"cmd\":\"ls\"}"}"#,
                #"data: {"type":"response.completed","response":{"id":"resp_c1","status":"completed","output":[],"usage":{"input_tokens":15,"output_tokens":9}}}"#
            ].joined(separator: "\n\n") + "\n\n"
            writer.startChunkedStream()
            _ = writer.writeStreamChunk(Data(events.utf8))
            writer.finishStream()
        }
        let codexPort = try codexMock.start(port: 0)
        defer { codexMock.stop() }

        let keychain = InMemoryKeychainService()
        let engine = AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: dir),
            keychain: keychain,
            alertNotifier: NoOpSystemAlertNotifier(),
            autoStartProxyIfConfigured: false
        )

        let acct = CodexSubscriptionAccount(
            label: "pro@example.com",
            email: "pro@example.com",
            planType: "pro",
            accountID: "acct_pro_99",
            accessToken: "token_pro_99",
            expiresAt: Date().addingTimeInterval(3600),
            source: "oauth_login"
        )
        let added = try engine.addCodexSubscriptionAccount(acct, modelSlugs: ["gpt-5.4"])
        var provider = added.provider
        provider.baseURL = "http://127.0.0.1:\(codexPort)"
        try engine.upsertProvider(provider, apiKeys: nil)

        // Assign gpt-5.4 directly as High tier base model
        let codexModel = try XCTUnwrap(engine.config.models.first(where: { $0.modelID == "gpt-5.4" }))
        engine.assignModelAsBaseTier(codexModel.id, tier: .high)
        XCTAssertEqual(engine.model(for: .high)?.id, codexModel.id)

        let proxyPort = try XCTUnwrap(LoopbackHTTPServer.findAvailablePort(startingFrom: 25_600))
        engine.updateProxyPort(proxyPort)
        engine.startProxy()
        defer { engine.stopProxy() }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(engine.localAPIToken, forHTTPHeaderField: "x-api-key")
        let anthropicReq: [String: Any] = [
            "model": "claude-opus-4-1",
            "max_tokens": 2048,
            "temperature": 0.2,
            "stream": true,
            "system": "You are Claude Code.",
            "tools": [[
                "name": "bash",
                "description": "Run shell command",
                "input_schema": [
                    "type": "object",
                    "properties": ["cmd": ["type": "string"]]
                ]
            ]],
            "tool_choice": ["type": "auto"],
            "messages": [
                ["role": "user", "content": "list files"]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: anthropicReq)

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        let sseText = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(sseText.contains("event: message_start"))
        XCTAssertTrue(sseText.contains("\"type\":\"thinking_delta\""))
        XCTAssertTrue(sseText.contains("Checking repo..."))
        XCTAssertTrue(sseText.contains("\"type\":\"text_delta\""))
        XCTAssertTrue(sseText.contains("Let me run a check."))
        XCTAssertTrue(sseText.contains("\"type\":\"tool_use\""))
        XCTAssertTrue(sseText.contains("\"name\":\"bash\""))
        XCTAssertTrue(sseText.contains("\"type\":\"input_json_delta\""))
        XCTAssertTrue(sseText.contains("\"stop_reason\":\"tool_use\""))
        XCTAssertTrue(sseText.contains("event: message_stop"))

        // Verify Codex backend received properly sanitized payload + ChatGPT-Account-Id header
        let sent = try XCTUnwrap(capture.snapshot().first)
        XCTAssertEqual(sent.path, "/responses")
        XCTAssertEqual(sent.accountID, "acct_pro_99")
        XCTAssertEqual(sent.originator, "codex_cli_rs")
        let sentObj = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.bodyData) as? [String: Any])
        XCTAssertEqual(sentObj["model"] as? String, "gpt-5.4")
        XCTAssertEqual(sentObj["store"] as? Bool, false)
        XCTAssertEqual(sentObj["instructions"] as? String, "You are Claude Code.")
        XCTAssertNil(sentObj["max_output_tokens"], "Codex backend rejects max_output_tokens")
        XCTAssertNil(sentObj["temperature"], "Codex backend rejects temperature")
    }

    // MARK: - 5. Built-in PKCE OAuth Session Completion & State Validation

    func testCodexOAuthLoginSessionCompleteAndStateValidation() async throws {
        let futureExp = Date().addingTimeInterval(3600).timeIntervalSince1970
        let jwt = makeFakeJWT(email: "oauth@example.com", accountID: "acct_oauth_77", planType: "plus", exp: futureExp)

        let oauthServer = LoopbackHTTPServer { req, writer in
            let body = String(data: req.body, encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("grant_type=authorization_code"))
            XCTAssertTrue(body.contains("code=auth_code_xyz"))
            let resp: [String: Any] = [
                "access_token": jwt,
                "refresh_token": "rt_oauth_77",
                "id_token": jwt,
                "expires_in": 3600
            ]
            writer.sendJSON(statusCode: 200, body: (try? JSONSerialization.data(withJSONObject: resp)) ?? Data())
        }
        let oauthPort = try oauthServer.start(port: 0)
        defer { oauthServer.stop() }

        let cfg = CodexOAuthConfiguration(
            clientID: "test-client",
            authorizeEndpoint: URL(string: "http://127.0.0.1:\(oauthPort)/oauth/authorize")!,
            tokenEndpoint: URL(string: "http://127.0.0.1:\(oauthPort)/oauth/token")!,
            redirectURI: "http://localhost:1455/auth/callback",
            callbackPort: 0
        )
        let session = CodexOAuthLoginSession(configuration: cfg)
        XCTAssertTrue(session.authorizeURL.absoluteString.contains("code_challenge_method=S256"))

        let task = Task {
            try await session.startAndAwaitAccount()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await session.completeWithCallbackURL("http://localhost:1455/auth/callback?code=auth_code_xyz&state=\(session.state)")
        let account = try await task.value
        XCTAssertEqual(account.email, "oauth@example.com")
        XCTAssertEqual(account.accountID, "acct_oauth_77")
        XCTAssertEqual(account.refreshToken, "rt_oauth_77")
        XCTAssertEqual(account.source, "oauth_login")

        // Mismatched state must reject
        let badSession = CodexOAuthLoginSession(configuration: cfg)
        let badTask = Task {
            try await badSession.startAndAwaitAccount()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await badSession.completeWithCallbackURL("http://localhost:1455/auth/callback?code=auth_code_xyz&state=wrong-state")
        do {
            _ = try await badTask.value
            XCTFail("Expected stateMismatch error")
        } catch let err as CodexOAuthError {
            guard case .stateMismatch = err else {
                return XCTFail("Unexpected error: \(err)")
            }
        }
    }

    // MARK: - 6. Default Available-Only Filtering for Providers & Provider Models

    @MainActor
    func testProviderAndModelAvailabilityFiltersHideUnreachableByDefault() throws {
        let dir = makeTempDir("visibility")
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: dir),
            keychain: InMemoryKeychainService(),
            alertNotifier: NoOpSystemAlertNotifier(),
            autoStartProxyIfConfigured: false
        )

        let healthyProvider = ProviderConfig(name: "Healthy", baseURL: "https://ok.example.com/v1", healthStatus: .healthy)
        let networkErrProvider = ProviderConfig(name: "Offline", baseURL: "https://offline.example.com/v1", healthStatus: .networkError)
        let disabledProvider = ProviderConfig(name: "Disabled", baseURL: "https://off.example.com/v1", isEnabled: false, healthStatus: .healthy)
        let allEvictedProvider = ProviderConfig(name: "AllEvicted", baseURL: "https://evicted.example.com/v1", healthStatus: .healthy)

        try engine.upsertProvider(healthyProvider, apiKeys: ["k1"])
        try engine.upsertProvider(networkErrProvider, apiKeys: ["k2"])
        try engine.upsertProvider(disabledProvider, apiKeys: ["k3"])
        try engine.upsertProvider(allEvictedProvider, apiKeys: ["k4"])

        let okModel = ModelConfig(providerID: healthyProvider.id, modelID: "m-ok", isEnabled: true, availabilityStatus: .available)
        let evictedModel = ModelConfig(providerID: healthyProvider.id, modelID: "m-dead", isEnabled: true, availabilityStatus: .unavailable, isAutoEvicted: true)
        let offlineModel = ModelConfig(providerID: networkErrProvider.id, modelID: "m-offline", isEnabled: true, availabilityStatus: .available)
        let evictedOnlyModel = ModelConfig(providerID: allEvictedProvider.id, modelID: "m-evicted-only", isEnabled: true, availabilityStatus: .unavailable, isAutoEvicted: true)

        engine.upsertModel(okModel)
        engine.upsertModel(evictedModel)
        engine.upsertModel(offlineModel)
        engine.upsertModel(evictedOnlyModel)

        XCTAssertTrue(engine.isProviderAvailable(healthyProvider))
        XCTAssertFalse(engine.isProviderAvailable(networkErrProvider))
        XCTAssertFalse(engine.isProviderAvailable(disabledProvider))
        XCTAssertFalse(engine.isProviderAvailable(allEvictedProvider))

        XCTAssertTrue(engine.isModelAvailable(okModel, provider: healthyProvider))
        XCTAssertFalse(engine.isModelAvailable(evictedModel, provider: healthyProvider))
        XCTAssertFalse(engine.isModelAvailable(offlineModel, provider: networkErrProvider))
    }
}
