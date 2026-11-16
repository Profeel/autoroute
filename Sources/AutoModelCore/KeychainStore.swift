import Foundation
import Security

public protocol KeychainServiceProtocol: Sendable {
    func setAPIKey(_ key: String, for providerID: UUID) throws
    func getAPIKey(for providerID: UUID) throws -> String?
    func deleteAPIKey(for providerID: UUID) throws
    func hasAPIKey(for providerID: UUID) -> Bool
    func allKnownSecretValues() -> [String]
    func clearAll() throws
}

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
    private let service: String
    private let lock = NSLock()
    private var cachedKeys: [UUID: String] = [:]

    public init(service: String = "org.automodel.app.apikeys") {
        self.service = service
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

        let existingStatus = SecItemCopyMatching(baseQuery as CFDictionary, nil)
        if existingStatus == errSecSuccess {
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        } else if existingStatus == errSecItemNotFound {
            var newItem = baseQuery
            newItem[kSecValueData as String] = data
            newItem[kSecAttrLabel as String] = "Auto Model Provider API Key"
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else {
            throw KeychainError.unexpectedStatus(existingStatus)
        }

        cachedKeys[providerID] = trimmed
    }

    public func getAPIKey(for providerID: UUID) throws -> String? {
        lock.lock()
        if let cached = cachedKeys[providerID] {
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
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        lock.lock()
        cachedKeys[providerID] = string
        lock.unlock()
        return string
    }

    public func deleteAPIKey(for providerID: UUID) throws {
        lock.lock()
        cachedKeys.removeValue(forKey: providerID)
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func hasAPIKey(for providerID: UUID) -> Bool {
        (try? getAPIKey(for: providerID))?.isEmpty == false
    }

    public func allKnownSecretValues() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return cachedKeys.values.filter { !$0.isEmpty }
    }

    public func clearAll() throws {
        lock.lock()
        cachedKeys.removeAll()
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// Thread-safe in-memory keychain implementation used in automated tests.
public final class InMemoryKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

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

    public func allKnownSecretValues() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.filter { !$0.isEmpty }
    }

    public func clearAll() throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
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
