import Foundation
import Security

/// Generates and verifies the credential used only by the local AutoRoute API.
/// Provider credentials continue to use their own UUID-based Keychain entries.
public enum LocalAPITokenManager {
    public static func loadOrCreate(keychain: any KeychainServiceProtocol) throws -> String {
        if let existing = try keychain.getLocalAPIToken(), !existing.isEmpty {
            return existing
        }
        let token = try generate()
        try keychain.setLocalAPIToken(token)
        return token
    }

    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        return Data(bytes).base64EncodedString()
    }

    /// Compares every byte and does not return early on the first mismatch.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= Int(a ^ b)
        }
        return difference == 0
    }
}

public struct LocalAPIRejection: Equatable, Sendable {
    public let statusCode: Int
    public let code: String
    public let message: String

    public init(statusCode: Int, code: String, message: String) {
        self.statusCode = statusCode
        self.code = code
        self.message = message
    }
}

/// Single security boundary for every local HTTP endpoint, including OPTIONS.
public enum LocalAPIRequestSecurity {
    public static func rejection(
        for request: HTTPRequestMessage,
        port: Int,
        token: String
    ) -> LocalAPIRejection? {
        guard isAllowedHost(request.header("Host"), port: port) else {
            return LocalAPIRejection(
                statusCode: 403,
                code: "invalid_host",
                message: "Host 必须是本地代理实际监听的 loopback 地址与端口。"
            )
        }

        if let origin = request.header("Origin"), !isLoopbackOrigin(origin) {
            return LocalAPIRejection(
                statusCode: 403,
                code: "invalid_origin",
                message: "仅允许明确的 loopback Origin；跨域授权默认关闭。"
            )
        }

        let isAnonymousHealth = request.method == "GET" && (request.path == "/health" || request.path == "/v1/health")
        guard !isAnonymousHealth else { return nil }

        let bearer: String? = {
            guard let authorization = request.header("Authorization") else { return nil }
            let parts = authorization.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
            return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let supplied = bearer ?? request.header("x-api-key")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let supplied, LocalAPITokenManager.constantTimeEquals(supplied, token) else {
            return LocalAPIRejection(
                statusCode: 401,
                code: "unauthorized",
                message: "需要有效的本地 API token；请使用 Authorization: Bearer 或 x-api-key。"
            )
        }
        return nil
    }

    private static func isAllowedHost(_ rawHost: String?, port: Int) -> Bool {
        guard let host = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !host.isEmpty else {
            return false
        }
        let allowed = Set(["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"])
        return allowed.contains(host)
    }

    private static func isLoopbackOrigin(_ rawOrigin: String) -> Bool {
        guard let components = URLComponents(string: rawOrigin),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
