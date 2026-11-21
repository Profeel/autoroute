import CryptoKit
import Foundation

// MARK: - Codex Subscription Account Models

/// Non-secret metadata for a Codex/ChatGPT subscription account stored in config.json.
public struct CodexAccountSummary: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var email: String?
    public var planType: String?
    public var accountID: String?
    public var expiresAt: Date?
    public var source: String
    public var lastRefreshedAt: Date?

    public init(
        id: UUID = UUID(),
        label: String,
        email: String? = nil,
        planType: String? = nil,
        accountID: String? = nil,
        expiresAt: Date? = nil,
        source: String = "codex_cli",
        lastRefreshedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.email = email
        self.planType = planType
        self.accountID = accountID
        self.expiresAt = expiresAt
        self.source = source
        self.lastRefreshedAt = lastRefreshedAt
    }

    public var displayTitle: String {
        let base = (email?.isEmpty == false) ? email! : label
        if let planType, !planType.isEmpty {
            return "\(base) (\(planType.uppercased()))"
        }
        return base
    }

    public func isExpiredOrExpiringSoon(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(leeway) >= expiresAt
    }
}

/// Full Codex/ChatGPT subscription credential persisted exclusively inside macOS Keychain.
public struct CodexSubscriptionAccount: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var email: String?
    public var planType: String?
    public var accountID: String?
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var source: String
    public var lastRefreshedAt: Date?

    public init(
        id: UUID = UUID(),
        label: String,
        email: String? = nil,
        planType: String? = nil,
        accountID: String? = nil,
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        source: String = "codex_cli",
        lastRefreshedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.email = email
        self.planType = planType
        self.accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.refreshToken = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.expiresAt = expiresAt
        self.source = source
        self.lastRefreshedAt = lastRefreshedAt
    }

    public var summary: CodexAccountSummary {
        CodexAccountSummary(
            id: id,
            label: label,
            email: email,
            planType: planType,
            accountID: accountID,
            expiresAt: effectiveExpiresAt,
            source: source,
            lastRefreshedAt: lastRefreshedAt
        )
    }

    public var effectiveExpiresAt: Date? {
        expiresAt ?? CodexJWTClaims.parse(accessToken).expiresAt
    }

    public var canRefresh: Bool {
        (refreshToken?.isEmpty == false) || source == "codex_cli"
    }

    public func isExpiredOrExpiringSoon(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        guard let exp = effectiveExpiresAt else { return false }
        return now.addingTimeInterval(leeway) >= exp
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Keychain Pool Codec

public enum CodexAccountPoolCodec {
    public static let prefix = "autoroute-codex-pool-v1:"

    public static func encode(_ accounts: [CodexSubscriptionAccount]) -> String {
        let cleaned = accounts.filter { !$0.accessToken.isEmpty }
        guard !cleaned.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cleaned),
              let json = String(data: data, encoding: .utf8) else {
            return cleaned[0].accessToken
        }
        return prefix + json
    }

    public static func decode(_ raw: String?, fallbackAccountID: String? = nil) -> [CodexSubscriptionAccount] {
        guard let raw else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.hasPrefix(prefix) {
            let jsonPart = String(trimmed.dropFirst(prefix.count))
            if let data = jsonPart.data(using: .utf8) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let decoded = try? decoder.decode([CodexSubscriptionAccount].self, from: data) {
                    return decoded.filter { !$0.accessToken.isEmpty }
                }
            }
            return []
        }

        // Backwards compatibility: legacy raw token(s) stored via APIKeyPoolCodec
        let rawTokens = APIKeyPoolCodec.decode(trimmed)
        return rawTokens.enumerated().map { idx, token in
            let claims = CodexJWTClaims.parse(token)
            let resolvedAcctID = claims.accountID ?? (idx == 0 ? fallbackAccountID : nil)
            let defaultLabel = claims.email ?? (rawTokens.count > 1 ? "Codex 订阅 #\(idx + 1)" : "Codex 订阅")
            return CodexSubscriptionAccount(
                label: defaultLabel,
                email: claims.email,
                planType: claims.planType,
                accountID: resolvedAcctID,
                accessToken: token,
                refreshToken: nil,
                expiresAt: claims.expiresAt,
                source: "codex_cli"
            )
        }
    }

    public static func extractSecretsForRedaction(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return [] }
        let accounts = decode(trimmed)
        var secrets: [String] = []
        for acct in accounts {
            secrets.append(acct.accessToken)
            if let refresh = acct.refreshToken, !refresh.isEmpty {
                secrets.append(refresh)
            }
        }
        return secrets
    }

    /// Merges incoming accounts into an existing pool, updating matching accounts in place while preserving IDs.
    public static func mergeAccounts(
        existing: [CodexSubscriptionAccount],
        incoming: [CodexSubscriptionAccount]
    ) -> [CodexSubscriptionAccount] {
        var result = existing
        for inc in incoming where !inc.accessToken.isEmpty {
            if let matchIdx = result.firstIndex(where: { cur in
                if let a1 = cur.accountID, let a2 = inc.accountID, !a1.isEmpty, a1 == a2 {
                    if let e1 = cur.email, let e2 = inc.email, !e1.isEmpty, !e2.isEmpty {
                        return e1.caseInsensitiveCompare(e2) == .orderedSame
                    }
                    return true
                }
                if let e1 = cur.email, let e2 = inc.email, !e1.isEmpty, e1.caseInsensitiveCompare(e2) == .orderedSame {
                    return true
                }
                return cur.accessToken == inc.accessToken || cur.id == inc.id
            }) {
                var merged = result[matchIdx]
                merged.accessToken = inc.accessToken
                if let newRefresh = inc.refreshToken, !newRefresh.isEmpty {
                    merged.refreshToken = newRefresh
                }
                if let exp = inc.expiresAt ?? inc.effectiveExpiresAt {
                    merged.expiresAt = exp
                }
                if let acctID = inc.accountID, !acctID.isEmpty {
                    merged.accountID = acctID
                }
                if let email = inc.email, !email.isEmpty {
                    merged.email = email
                }
                if let plan = inc.planType, !plan.isEmpty {
                    merged.planType = plan
                }
                if !inc.label.isEmpty && (merged.label.hasPrefix("Codex 订阅") || inc.email != nil) {
                    merged.label = inc.label
                }
                if !inc.source.isEmpty {
                    merged.source = inc.source
                }
                merged.lastRefreshedAt = inc.lastRefreshedAt ?? Date()
                result[matchIdx] = merged
            } else {
                var appended = inc
                if appended.label.isEmpty || appended.label == "Codex 订阅", result.count >= 1 {
                    appended.label = inc.email ?? "Codex 订阅 #\(result.count + 1)"
                }
                result.append(appended)
            }
        }
        return result
    }
}

// MARK: - JWT Claims Parser

public struct CodexJWTClaims: Sendable {
    public let accountID: String?
    public let email: String?
    public let planType: String?
    public let expiresAt: Date?

    public static func parse(_ jwt: String) -> CodexJWTClaims {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else {
            return CodexJWTClaims(accountID: nil, email: nil, planType: nil, expiresAt: nil)
        }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = b64.count % 4
        if remainder != 0 {
            b64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CodexJWTClaims(accountID: nil, email: nil, planType: nil, expiresAt: nil)
        }

        let authDict = obj["https://api.openai.com/auth"] as? [String: Any]
        let profileDict = obj["https://api.openai.com/profile"] as? [String: Any]

        let accountID = (authDict?["chatgpt_account_id"] as? String)
            ?? (obj["chatgpt_account_id"] as? String)
        let planType = (authDict?["chatgpt_plan_type"] as? String)
            ?? (obj["chatgpt_plan_type"] as? String)
        let email = (obj["email"] as? String)
            ?? (profileDict?["email"] as? String)

        var expiresAt: Date?
        if let exp = obj["exp"] as? TimeInterval {
            expiresAt = Date(timeIntervalSince1970: exp)
        } else if let expInt = obj["exp"] as? Int {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(expInt))
        }

        return CodexJWTClaims(
            accountID: accountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            email: email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            planType: planType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            expiresAt: expiresAt
        )
    }
}

// MARK: - ~/.codex/auth.json & models_cache.json Parser

public enum CodexAuthFileParser {
    public static func defaultCodexDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func defaultAuthURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        defaultCodexDirectory(homeDirectory: homeDirectory).appendingPathComponent("auth.json")
    }

    public static func parseAuthFile(at url: URL) -> CodexSubscriptionAccount? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = (tokens["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return nil
        }

        let refreshToken = (tokens["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let idToken = (tokens["id_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let explicitAccountID = (tokens["account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        let accessClaims = CodexJWTClaims.parse(accessToken)
        let idClaims = idToken.map { CodexJWTClaims.parse($0) }

        let accountID = explicitAccountID ?? idClaims?.accountID ?? accessClaims.accountID
        let email = idClaims?.email ?? accessClaims.email
        let planType = idClaims?.planType ?? accessClaims.planType
        let expiresAt = accessClaims.expiresAt ?? idClaims?.expiresAt

        var lastRefreshedAt: Date?
        if let rawLastRefresh = root["last_refresh"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            lastRefreshedAt = iso.date(from: rawLastRefresh) ?? ISO8601DateFormatter().date(from: rawLastRefresh)
        }

        let label = email ?? "Codex CLI 订阅"
        return CodexSubscriptionAccount(
            label: label,
            email: email,
            planType: planType,
            accountID: accountID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            source: "codex_cli",
            lastRefreshedAt: lastRefreshedAt
        )
    }

    public static func collectModelSlugs(codexDir: URL) -> [String] {
        var modelSlugs: [String] = []
        var slugSet = Set<String>()
        for cacheName in ["models_cache.json", "models_cache.local.json", "models_cache.codex_work_desktop.json"] {
            let cacheURL = codexDir.appendingPathComponent(cacheName)
            guard let data = try? Data(contentsOf: cacheURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = root["models"] as? [[String: Any]] else {
                continue
            }
            for item in models {
                guard let slug = (item["slug"] as? String) ?? (item["id"] as? String),
                      !slug.isEmpty else {
                    continue
                }
                let visibility = (item["visibility"] as? String)?.lowercased() ?? "list"
                if visibility == "hide" || slug == "codex-auto-review" {
                    continue
                }
                if slugSet.insert(slug).inserted {
                    modelSlugs.append(slug)
                }
            }
            if !modelSlugs.isEmpty { break }
        }

        if modelSlugs.isEmpty {
            modelSlugs = ["gpt-5.4", "gpt-5.3-codex", "gpt-5.4-mini"]
        }
        return modelSlugs
    }
}

// MARK: - Codex OAuth Client & Refresh Coordinator

public struct CodexOAuthConfiguration: Sendable {
    public var clientID: String
    public var authorizeEndpoint: URL
    public var tokenEndpoint: URL
    public var redirectURI: String
    public var callbackPort: Int

    public static let standard = CodexOAuthConfiguration(
        clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
        authorizeEndpoint: URL(string: "https://auth.openai.com/oauth/authorize")!,
        tokenEndpoint: URL(string: "https://auth.openai.com/oauth/token")!,
        redirectURI: "http://localhost:1455/auth/callback",
        callbackPort: 1455
    )

    public init(
        clientID: String = "app_EMoamEEZ73f0CkXaXp7hrann",
        authorizeEndpoint: URL = URL(string: "https://auth.openai.com/oauth/authorize")!,
        tokenEndpoint: URL = URL(string: "https://auth.openai.com/oauth/token")!,
        redirectURI: String = "http://localhost:1455/auth/callback",
        callbackPort: Int = 1455
    ) {
        self.clientID = clientID
        self.authorizeEndpoint = authorizeEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.redirectURI = redirectURI
        self.callbackPort = callbackPort
    }
}

public enum CodexOAuthError: Error, LocalizedError, Sendable {
    case missingRefreshToken
    case invalidCallbackURL(String)
    case stateMismatch
    case authorizationDenied(String)
    case tokenExchangeFailed(statusCode: Int, message: String, isInvalidGrant: Bool)
    case networkError(String)
    case invalidResponse(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingRefreshToken:
            return "该 Codex 订阅账号缺少 refresh_token，请重新登录或重新从 Codex CLI 导入。"
        case .invalidCallbackURL(let detail):
            return "回调 URL 无效：\(detail)"
        case .stateMismatch:
            return "OAuth state 校验失败，请重新发起登录。"
        case .authorizationDenied(let msg):
            return "ChatGPT 授权被拒绝：\(msg)"
        case .tokenExchangeFailed(let status, let msg, _):
            return "Codex OAuth Token 请求失败 (HTTP \(status)): \(msg)"
        case .networkError(let msg):
            return "Codex OAuth 网络错误：\(msg)"
        case .invalidResponse(let msg):
            return "Codex OAuth 响应异常：\(msg)"
        case .cancelled:
            return "已取消 ChatGPT 登录。"
        }
    }
}

public final class CodexOAuthClient: @unchecked Sendable {
    public let configuration: CodexOAuthConfiguration
    private let session: URLSession

    public init(
        configuration: CodexOAuthConfiguration = .standard,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 20
            cfg.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: cfg)
        }
    }

    public func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        source: String = "oauth_login"
    ) async throws -> CodexSubscriptionAccount {
        let params: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("client_id", configuration.clientID),
            ("code", code),
            ("redirect_uri", configuration.redirectURI),
            ("code_verifier", codeVerifier)
        ]
        let payload = try await postForm(params: params)
        return try buildAccount(fromTokenPayload: payload, existing: nil, source: source)
    }

    public func refresh(account: CodexSubscriptionAccount) async throws -> CodexSubscriptionAccount {
        guard let refreshToken = account.refreshToken, !refreshToken.isEmpty else {
            throw CodexOAuthError.missingRefreshToken
        }
        let params: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("client_id", configuration.clientID),
            ("refresh_token", refreshToken)
        ]
        let payload = try await postForm(params: params)
        return try buildAccount(fromTokenPayload: payload, existing: account, source: account.source)
    }

    private func postForm(params: [(String, String)]) async throws -> [String: Any] {
        var req = URLRequest(url: configuration.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = formEncode(params).data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw CodexOAuthError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CodexOAuthError.invalidResponse("未收到有效 HTTP 响应")
        }

        let jsonObj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        guard (200...299).contains(http.statusCode) else {
            let errCode = (jsonObj?["error"] as? String)
                ?? ((jsonObj?["error"] as? [String: Any])?["code"] as? String)
                ?? ""
            let errDesc = (jsonObj?["error_description"] as? String)
                ?? ((jsonObj?["error"] as? [String: Any])?["message"] as? String)
                ?? (jsonObj?["error"] as? String)
                ?? (String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
                ?? "HTTP \(http.statusCode)"
            let lower = "\(errCode) \(errDesc)".lowercased()
            let isInvalidGrant = lower.contains("invalid_grant")
                || lower.contains("refresh_token_reused")
                || lower.contains("refresh token was already used")
                || lower.contains("token_revoked")
            throw CodexOAuthError.tokenExchangeFailed(statusCode: http.statusCode, message: errDesc, isInvalidGrant: isInvalidGrant)
        }

        guard let jsonObj else {
            throw CodexOAuthError.invalidResponse("Token 接口未返回 JSON 对象")
        }
        return jsonObj
    }

    private func buildAccount(
        fromTokenPayload json: [String: Any],
        existing: CodexSubscriptionAccount?,
        source: String
    ) throws -> CodexSubscriptionAccount {
        guard let accessToken = (json["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            throw CodexOAuthError.invalidResponse("响应缺少 access_token")
        }
        let refreshToken = (json["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? existing?.refreshToken
        let idToken = (json["id_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        let accessClaims = CodexJWTClaims.parse(accessToken)
        let idClaims = idToken.map { CodexJWTClaims.parse($0) }

        var expiresAt = accessClaims.expiresAt ?? idClaims?.expiresAt
        if expiresAt == nil, let expiresIn = (json["expires_in"] as? TimeInterval) ?? (json["expires_in"] as? Int).map(TimeInterval.init) {
            expiresAt = Date().addingTimeInterval(expiresIn)
        }

        let accountID = idClaims?.accountID ?? accessClaims.accountID ?? existing?.accountID
        let email = idClaims?.email ?? accessClaims.email ?? existing?.email
        let planType = idClaims?.planType ?? accessClaims.planType ?? existing?.planType
        let label = email ?? existing?.label ?? "Codex 订阅"

        return CodexSubscriptionAccount(
            id: existing?.id ?? UUID(),
            label: label,
            email: email,
            planType: planType,
            accountID: accountID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            source: source,
            lastRefreshedAt: Date()
        )
    }

    private func formEncode(_ params: [(String, String)]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}

/// Coalesces concurrent token refreshes for the same account so single-use refresh tokens never race.
public actor CodexTokenRefreshCoordinator {
    private var inFlightByAccountID: [UUID: Task<CodexSubscriptionAccount, Error>] = [:]

    public init() {}

    public func refresh(
        account: CodexSubscriptionAccount,
        using client: CodexOAuthClient
    ) async throws -> CodexSubscriptionAccount {
        if let existingTask = inFlightByAccountID[account.id] {
            return try await existingTask.value
        }

        let task = Task<CodexSubscriptionAccount, Error> {
            try await client.refresh(account: account)
        }
        inFlightByAccountID[account.id] = task
        defer { inFlightByAccountID.removeValue(forKey: account.id) }
        return try await task.value
    }
}

// MARK: - Built-in PKCE Browser OAuth Login Session

public final class CodexOAuthLoginSession: @unchecked Sendable {
    public let configuration: CodexOAuthConfiguration
    public let authorizeURL: URL
    public let state: String
    public let codeVerifier: String
    public private(set) var loopbackPortOccupied = false

    private let client: CodexOAuthClient
    private let lock = NSLock()
    private var server: LoopbackHTTPServer?
    private var continuation: CheckedContinuation<CodexSubscriptionAccount, Error>?
    private var isCompleted = false

    public init(
        configuration: CodexOAuthConfiguration = .standard,
        client: CodexOAuthClient? = nil
    ) {
        self.configuration = configuration
        self.client = client ?? CodexOAuthClient(configuration: configuration)
        self.codeVerifier = Self.randomBase64URL(byteCount: 64)
        self.state = Self.randomBase64URL(byteCount: 24)
        let challenge = Self.sha256Base64URL(self.codeVerifier)

        var components = URLComponents(url: configuration.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
            URLQueryItem(name: "state", value: self.state)
        ]
        self.authorizeURL = components.url!
    }

    deinit {
        stopServer()
    }

    /// Starts the local callback listener (127.0.0.1:1455) if available and waits for OAuth completion.
    public func startAndAwaitAccount() async throws -> CodexSubscriptionAccount {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock {
                self.continuation = cont
            }
            let callbackServer = LoopbackHTTPServer { [weak self] req, writer in
                guard let self else {
                    writer.close()
                    return
                }
                await self.handleCallbackRequest(req, writer: writer)
            }
            do {
                try callbackServer.start(port: configuration.callbackPort)
                lock.withLock { self.server = callbackServer }
            } catch {
                // Port 1455 might already be bound by Codex CLI; caller can still paste callback URL manually.
                lock.withLock { self.loopbackPortOccupied = true }
            }
        }
    }

    /// Completes the login session from a manually pasted redirect URL (`http://localhost:1455/auth/callback?code=...&state=...`).
    public func completeWithCallbackURL(_ rawURLString: String) async {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            finish(with: .failure(CodexOAuthError.invalidCallbackURL("请粘贴完整的 http://localhost:1455/auth/callback?... 链接")))
            return
        }
        await processCallbackQueryItems(comps.queryItems ?? [])
    }

    public func cancel() {
        finish(with: .failure(CodexOAuthError.cancelled))
    }

    private func handleCallbackRequest(_ req: HTTPRequestMessage, writer: HTTPConnectionWriter) async {
        guard req.method == "GET", req.path == "/auth/callback" else {
            writer.sendJSON(
                statusCode: 404,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data("Not Found".utf8)
            )
            return
        }

        let comps = URLComponents(string: "http://localhost\(req.path)?\(req.query)")
        let queryItems = comps?.queryItems ?? []
        let outcome = await exchangeQueryItems(queryItems)

        switch outcome {
        case .success(let account):
            let title = account.displayNameForHTML
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>AutoRoute 登录成功</title>
            <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#f5f7fa;color:#111}
            .card{background:#fff;padding:32px 36px;border-radius:14px;box-shadow:0 8px 30px rgba(0,0,0,.08);text-align:center;max-width:420px}
            h2{margin:0 0 8px;color:#0a7f42}p{margin:0;color:#555;font-size:14px;line-height:1.6}</style></head>
            <body><div class="card"><h2>✓ Codex 订阅已连接</h2><p>账号 <b>\(title)</b> 已安全存入 AutoRoute Keychain。<br>您可以关闭此页面返回 AutoRoute。</p></div></body></html>
            """
            writer.sendJSON(
                statusCode: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: Data(html.utf8)
            )
            finish(with: .success(account))
        case .failure(let err):
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>AutoRoute 登录失败</title>
            <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#f5f7fa;color:#111}
            .card{background:#fff;padding:32px 36px;border-radius:14px;box-shadow:0 8px 30px rgba(0,0,0,.08);text-align:center;max-width:460px}
            h2{margin:0 0 8px;color:#b42318}p{margin:0;color:#555;font-size:14px;line-height:1.6}</style></head>
            <body><div class="card"><h2>登录未完成</h2><p>\(err.localizedDescription)</p></div></body></html>
            """
            writer.sendJSON(
                statusCode: 400,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: Data(html.utf8)
            )
            finish(with: .failure(err))
        }
    }

    private func processCallbackQueryItems(_ items: [URLQueryItem]) async {
        let outcome = await exchangeQueryItems(items)
        finish(with: outcome)
    }

    private func exchangeQueryItems(_ items: [URLQueryItem]) async -> Result<CodexSubscriptionAccount, Error> {
        let map = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let val = item.value else { return nil }
            return (item.name, val)
        })
        if let err = map["error"] {
            let desc = map["error_description"] ?? err
            return .failure(CodexOAuthError.authorizationDenied(desc))
        }
        guard map["state"] == state else {
            return .failure(CodexOAuthError.stateMismatch)
        }
        guard let code = map["code"], !code.isEmpty else {
            return .failure(CodexOAuthError.invalidCallbackURL("缺少 authorization code"))
        }
        do {
            let account = try await client.exchangeAuthorizationCode(code, codeVerifier: codeVerifier)
            return .success(account)
        } catch {
            return .failure(error)
        }
    }

    private func finish(with result: Result<CodexSubscriptionAccount, Error>) {
        let cont: CheckedContinuation<CodexSubscriptionAccount, Error>? = lock.withLock {
            guard !isCompleted else { return nil }
            isCompleted = true
            let c = continuation
            continuation = nil
            return c
        }
        stopServer()
        if let cont {
            cont.resume(with: result)
        }
    }

    private func stopServer() {
        let srv = lock.withLock { () -> LoopbackHTTPServer? in
            let s = server
            server = nil
            return s
        }
        srv?.stop()
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func sha256Base64URL(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension CodexSubscriptionAccount {
    var displayNameForHTML: String {
        let raw = email ?? label
        return raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
