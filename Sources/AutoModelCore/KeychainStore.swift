import Darwin
import Foundation
import Security

/// Process-local knowledge; unknown includes unattempted and failed reads.
public enum CachedAPIKey: Equatable, Sendable {
    case unknown, missing
    case found(String)
}

public protocol KeychainServiceProtocol: Sendable {
    func setAPIKey(_ key: String, for providerID: UUID) throws
    func getAPIKey(for providerID: UUID) throws -> String?
    /// Must not perform Keychain I/O.
    func cachedAPIKey(for providerID: UUID) -> CachedAPIKey
    func deleteAPIKey(for providerID: UUID) throws
    func hasAPIKey(for providerID: UUID) -> Bool
    func setLocalAPIToken(_ token: String) throws
    func getLocalAPIToken() throws -> String?
    func setLocalModelAPIKey(_ key: String) throws
    func getLocalModelAPIKey() throws -> String?
    func deleteLocalModelAPIKey() throws
    func allKnownSecretValues() -> [String]
    func clearAll() throws
}

public enum APIKeyPoolCodec {
    public static let prefix = "autoroute-keypool-v1:"

    /// Normalizes a list of keys: trims whitespace, drops empties, and deduplicates while preserving order.
    public static func normalize(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in keys {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Encodes 0 keys as `""`, 1 key verbatim (backwards-compatible), and 2+ keys with a versioned prefix.
    public static func encode(_ keys: [String]) -> String {
        let cleaned = normalize(keys)
        if cleaned.isEmpty { return "" }
        if cleaned.count == 1 { return cleaned[0] }
        guard let data = try? JSONEncoder().encode(cleaned),
              let json = String(data: data, encoding: .utf8) else {
            return cleaned[0]
        }
        return prefix + json
    }

    /// Decodes either a legacy single-key raw string, a multi-key pool payload, or a Codex subscription account pool payload.
    public static func decode(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix(CodexAccountPoolCodec.prefix) {
            return normalize(CodexAccountPoolCodec.decode(trimmed).map(\.accessToken))
        }
        if trimmed.hasPrefix(prefix) {
            let jsonPart = String(trimmed.dropFirst(prefix.count))
            if let data = jsonPart.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                return normalize(decoded)
            }
        }
        return [trimmed]
    }

    /// Extracts all sensitive substrings (including refresh tokens inside Codex account pools) for redaction.
    public static func extractAllSecrets(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var secrets = [trimmed]
        if trimmed.hasPrefix(CodexAccountPoolCodec.prefix) {
            secrets.append(contentsOf: CodexAccountPoolCodec.extractSecretsForRedaction(trimmed))
        } else {
            secrets.append(contentsOf: decode(trimmed))
        }
        return normalize(secrets)
    }
}

public extension KeychainServiceProtocol {
    func cachedAPIKey(for providerID: UUID) -> CachedAPIKey { .unknown }

    func setAPIKeys(_ keys: [String], for providerID: UUID) throws {
        let encoded = APIKeyPoolCodec.encode(keys)
        if encoded.isEmpty {
            try deleteAPIKey(for: providerID)
        } else {
            try setAPIKey(encoded, for: providerID)
        }
    }

    func getAPIKeys(for providerID: UUID) throws -> [String] {
        APIKeyPoolCodec.decode(try getAPIKey(for: providerID))
    }

    func cachedAPIKeys(for providerID: UUID) -> [String]? {
        switch cachedAPIKey(for: providerID) {
        case .unknown:
            return nil
        case .missing:
            return []
        case .found(let raw):
            return APIKeyPoolCodec.decode(raw)
        }
    }

    func setCodexAccounts(_ accounts: [CodexSubscriptionAccount], for providerID: UUID) throws {
        let encoded = CodexAccountPoolCodec.encode(accounts)
        if encoded.isEmpty {
            try deleteAPIKey(for: providerID)
        } else {
            try setAPIKey(encoded, for: providerID)
        }
    }

    func getCodexAccounts(for providerID: UUID, fallbackAccountID: String? = nil) throws -> [CodexSubscriptionAccount] {
        CodexAccountPoolCodec.decode(try getAPIKey(for: providerID), fallbackAccountID: fallbackAccountID)
    }

    func cachedCodexAccounts(for providerID: UUID, fallbackAccountID: String? = nil) -> [CodexSubscriptionAccount]? {
        switch cachedAPIKey(for: providerID) {
        case .unknown:
            return nil
        case .missing:
            return []
        case .found(let raw):
            return CodexAccountPoolCodec.decode(raw, fallbackAccountID: fallbackAccountID)
        }
    }
}

/// Reserved account identifier; it cannot collide with normal random provider UUIDs in practice.
private let localAPITokenAccountUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let localModelAPIKeyAccount = "autoroute.local-model-api-key"

public enum KeychainError: LocalizedError, Sendable {
    case encodingFailed
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "API Key 编码失败"
        case .unexpectedStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "macOS Keychain 错误 (\(status)): \(message)"
            }
            return "macOS Keychain 错误 (\(status))"
        }
    }
}

/// Persists provider API keys inside macOS Keychain under service `org.automodel.app.apikeys`.
public final class MacOSKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private static let interactionLock = NSLock()
    private typealias SetUserInteractionAllowedFn = @convention(c) (DarwinBoolean) -> OSStatus
    private static let setUserInteractionAllowed: SetUserInteractionAllowedFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainSetUserInteractionAllowed") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetUserInteractionAllowedFn.self)
    }()

    private let service: String
    private let lock = NSLock()
    private var cachedKeys: [UUID: String] = [:]
    private var knownMissingKeys: Set<UUID> = []
    private var cachedLocalModelAPIKey: String?

    public init(service: String = "org.automodel.app.apikeys") {
        self.service = service
    }

    /// Suppresses legacy Keychain UI prompts so items with stale ACLs fail cleanly instead of looping password dialogs.
    private func withKeychainUserInteractionDisabled<T>(_ body: () -> T) -> T {
        Self.interactionLock.lock()
        defer { Self.interactionLock.unlock() }
        _ = Self.setUserInteractionAllowed?(false)
        defer { _ = Self.setUserInteractionAllowed?(true) }
        return body()
    }

    public func setAPIKey(_ key: String, for providerID: UUID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteAPIKey(for: providerID)
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        lock.lock()
        defer { lock.unlock() }

        let account = providerID.uuidString
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(deleteStatus)
        }

        var newItem = baseQuery
        newItem[kSecValueData as String] = data
        newItem[kSecAttrLabel as String] = providerID == localAPITokenAccountUUID
            ? "AutoRoute Local API Token"
            : "AutoRoute Provider API Key"
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }

        cachedKeys[providerID] = trimmed
        knownMissingKeys.remove(providerID)
    }

    public func getAPIKey(for providerID: UUID) throws -> String? {
        try getAPIKey(for: providerID, useCache: true)
    }

    private func getAPIKey(for providerID: UUID, useCache: Bool) throws -> String? {
        lock.lock()
        if useCache, let cached = cachedKeys[providerID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = withKeychainUserInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            if status != errSecItemNotFound {
                let deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: providerID.uuidString
                ]
                _ = SecItemDelete(deleteQuery as CFDictionary)
            }
            lock.lock()
            cachedKeys.removeValue(forKey: providerID)
            knownMissingKeys.insert(providerID)
            lock.unlock()
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.encodingFailed
        }

        lock.lock()
        cachedKeys[providerID] = string
        knownMissingKeys.remove(providerID)
        lock.unlock()
        return string
    }

    public func deleteAPIKey(for providerID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }
        lock.lock()
        cachedKeys.removeValue(forKey: providerID)
        knownMissingKeys.insert(providerID)
        lock.unlock()
    }

    public func cachedAPIKey(for providerID: UUID) -> CachedAPIKey {
        lock.lock()
        defer { lock.unlock() }
        if let key = cachedKeys[providerID] { return .found(key) }
        return knownMissingKeys.contains(providerID) ? .missing : .unknown
    }

    public func hasAPIKey(for providerID: UUID) -> Bool {
        if case .found(let key) = cachedAPIKey(for: providerID) { return !key.isEmpty }
        return false
    }

    public func setLocalAPIToken(_ token: String) throws {
        try setAPIKey(token, for: localAPITokenAccountUUID)
    }

    public func getLocalAPIToken() throws -> String? {
        // Durability checks must read the actual Keychain, not the process cache.
        try getAPIKey(for: localAPITokenAccountUUID, useCache: false)
    }

    public func setLocalModelAPIKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else { throw KeychainError.encodingFailed }
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: localModelAPIKeyAccount
        ]
        var status = withKeychainUserInteractionDisabled {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "AutoRoute Local Model API Key"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = withKeychainUserInteractionDisabled { SecItemAdd(item as CFDictionary, nil) }
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        cachedLocalModelAPIKey = key
    }

    public func getLocalModelAPIKey() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: localModelAPIKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = withKeychainUserInteractionDisabled { SecItemCopyMatching(query as CFDictionary, &result) }
        if status == errSecItemNotFound {
            cachedLocalModelAPIKey = nil
            return nil
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.encodingFailed
        }
        cachedLocalModelAPIKey = key
        return key
    }

    public func deleteLocalModelAPIKey() throws {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: localModelAPIKeyAccount
        ]
        let status = withKeychainUserInteractionDisabled { SecItemDelete(query as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
        cachedLocalModelAPIKey = nil
    }

    public func allKnownSecretValues() -> [String] {
        lock.lock()
        let rawValues = Array(cachedKeys.values) + [cachedLocalModelAPIKey].compactMap { $0 }
        lock.unlock()
        var secrets: [String] = []
        for raw in rawValues where !raw.isEmpty {
            secrets.append(contentsOf: APIKeyPoolCodec.extractAllSecrets(raw))
        }
        return APIKeyPoolCodec.normalize(secrets)
    }

    public func clearAll() throws {
        lock.lock()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            lock.unlock()
            throw KeychainError.unexpectedStatus(status)
        }
        cachedKeys.removeAll()
        knownMissingKeys.removeAll()
        cachedLocalModelAPIKey = nil
        lock.unlock()
    }
}

/// Thread-safe in-memory keychain implementation used in automated tests.
public final class InMemoryKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]
    private var localModelAPIKey: String?

    public init(initial: [UUID: String] = [:]) {
        self.storage = initial
    }

    public func setAPIKey(_ key: String, for providerID: UUID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        if trimmed.isEmpty {
            storage.removeValue(forKey: providerID)
        } else {
            storage[providerID] = trimmed
        }
    }

    public func getAPIKey(for providerID: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[providerID]
    }

    public func deleteAPIKey(for providerID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: providerID)
    }

    public func hasAPIKey(for providerID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[providerID]?.isEmpty == false
    }

    public func cachedAPIKey(for providerID: UUID) -> CachedAPIKey {
        lock.lock()
        defer { lock.unlock() }
        return storage[providerID].map { .found($0) } ?? .missing
    }

    public func setLocalAPIToken(_ token: String) throws {
        try setAPIKey(token, for: localAPITokenAccountUUID)
    }

    public func getLocalAPIToken() throws -> String? {
        try getAPIKey(for: localAPITokenAccountUUID)
    }

    public func setLocalModelAPIKey(_ key: String) throws {
        lock.withLock { localModelAPIKey = key }
    }

    public func getLocalModelAPIKey() throws -> String? {
        lock.withLock { localModelAPIKey }
    }

    public func deleteLocalModelAPIKey() throws {
        lock.withLock { localModelAPIKey = nil }
    }

    public func allKnownSecretValues() -> [String] {
        lock.lock()
        let rawValues = Array(storage.values) + [localModelAPIKey].compactMap { $0 }
        lock.unlock()
        var secrets: [String] = []
        for raw in rawValues where !raw.isEmpty {
            secrets.append(contentsOf: APIKeyPoolCodec.extractAllSecrets(raw))
        }
        return APIKeyPoolCodec.normalize(secrets)
    }

    public func clearAll() throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        localModelAPIKey = nil
    }
}

public enum SecretRedactor {
    public static func redact(_ text: String, secrets: [String]) -> String {
        var sanitized = text
        for secret in secrets where secret.count >= 4 {
            sanitized = sanitized.replacingOccurrences(of: secret, with: "[REDACTED_KEY]")
        }
        return sanitized
    }
}
