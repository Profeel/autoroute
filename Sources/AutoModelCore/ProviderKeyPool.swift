import CryptoKit
import Foundation

/// Thread-safe per-provider API key rotation and per-key cooldown tracker.
/// Keys are tracked exclusively by SHA-256 fingerprint so raw secrets are never retained in cooldown maps.
public final class ProviderKeyPoolRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var roundRobinCursorByProviderID: [UUID: Int] = [:]
    private var cooldownUntilByKeyFingerprint: [String: Date] = [:]

    public init() {}

    public func orderedKeys(
        for providerID: UUID,
        keys: [String],
        strategy: ProviderKeyRotationStrategy,
        now: Date = Date()
    ) -> [String] {
        let cleaned = APIKeyPoolCodec.normalize(keys)
        guard cleaned.count > 1 else { return cleaned }

        return lock.withLock {
            let rotated: [String]
            switch strategy {
            case .roundRobin:
                let cursor = roundRobinCursorByProviderID[providerID, default: 0] % cleaned.count
                roundRobinCursorByProviderID[providerID] = (cursor + 1) % cleaned.count
                rotated = Array(cleaned[cursor...]) + Array(cleaned[..<cursor])
            case .priorityFailover:
                rotated = cleaned
            }

            var active: [String] = []
            var cooling: [String] = []
            for key in rotated {
                let fp = Self.fingerprint(providerID: providerID, key: key)
                if let until = cooldownUntilByKeyFingerprint[fp], until > now {
                    cooling.append(key)
                } else {
                    cooldownUntilByKeyFingerprint.removeValue(forKey: fp)
                    active.append(key)
                }
            }
            return active + cooling
        }
    }

    public func markRateLimited(
        providerID: UUID,
        key: String,
        cooldownSeconds: TimeInterval = 60,
        now: Date = Date()
    ) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let fp = Self.fingerprint(providerID: providerID, key: trimmed)
        lock.withLock {
            cooldownUntilByKeyFingerprint[fp] = now.addingTimeInterval(max(1, cooldownSeconds))
        }
    }

    public func markAuthFailed(
        providerID: UUID,
        key: String,
        cooldownSeconds: TimeInterval = 600,
        now: Date = Date()
    ) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let fp = Self.fingerprint(providerID: providerID, key: trimmed)
        lock.withLock {
            cooldownUntilByKeyFingerprint[fp] = now.addingTimeInterval(max(1, cooldownSeconds))
        }
    }

    public func clearCooldown(providerID: UUID, key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let fp = Self.fingerprint(providerID: providerID, key: trimmed)
        _ = lock.withLock {
            cooldownUntilByKeyFingerprint.removeValue(forKey: fp)
        }
    }

    public func isCooling(providerID: UUID, key: String, now: Date = Date()) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let fp = Self.fingerprint(providerID: providerID, key: trimmed)
        return lock.withLock {
            guard let until = cooldownUntilByKeyFingerprint[fp] else { return false }
            return until > now
        }
    }

    public func reset(providerID: UUID? = nil) {
        lock.withLock {
            if let providerID {
                roundRobinCursorByProviderID.removeValue(forKey: providerID)
                let prefix = "\(providerID.uuidString)|"
                cooldownUntilByKeyFingerprint = cooldownUntilByKeyFingerprint.filter { !$0.key.hasPrefix(prefix) }
            } else {
                roundRobinCursorByProviderID.removeAll()
                cooldownUntilByKeyFingerprint.removeAll()
            }
        }
    }

    private static func fingerprint(providerID: UUID, key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(providerID.uuidString)|\(hex)"
    }

    // MARK: - Codex Subscription Account Pool

    public func orderedCodexAccounts(
        for providerID: UUID,
        accounts: [CodexSubscriptionAccount],
        strategy: ProviderKeyRotationStrategy,
        now: Date = Date()
    ) -> [CodexSubscriptionAccount] {
        guard accounts.count > 1 else { return accounts }
        return lock.withLock {
            let rotated: [CodexSubscriptionAccount]
            switch strategy {
            case .roundRobin:
                let cursor = roundRobinCursorByProviderID[providerID, default: 0] % accounts.count
                roundRobinCursorByProviderID[providerID] = (cursor + 1) % accounts.count
                rotated = Array(accounts[cursor...]) + Array(accounts[..<cursor])
            case .priorityFailover:
                rotated = accounts
            }

            var active: [CodexSubscriptionAccount] = []
            var cooling: [CodexSubscriptionAccount] = []
            for acct in rotated {
                let key = Self.accountKey(providerID: providerID, accountID: acct.id)
                if let until = cooldownUntilByKeyFingerprint[key], until > now {
                    cooling.append(acct)
                } else {
                    cooldownUntilByKeyFingerprint.removeValue(forKey: key)
                    active.append(acct)
                }
            }
            return active + cooling
        }
    }

    public func markAccountRateLimited(
        providerID: UUID,
        accountID: UUID,
        cooldownSeconds: TimeInterval = 60,
        now: Date = Date()
    ) {
        let key = Self.accountKey(providerID: providerID, accountID: accountID)
        lock.withLock {
            cooldownUntilByKeyFingerprint[key] = now.addingTimeInterval(max(1, cooldownSeconds))
        }
    }

    public func markAccountAuthFailed(
        providerID: UUID,
        accountID: UUID,
        cooldownSeconds: TimeInterval = 600,
        now: Date = Date()
    ) {
        let key = Self.accountKey(providerID: providerID, accountID: accountID)
        lock.withLock {
            cooldownUntilByKeyFingerprint[key] = now.addingTimeInterval(max(1, cooldownSeconds))
        }
    }

    public func clearAccountCooldown(providerID: UUID, accountID: UUID) {
        let key = Self.accountKey(providerID: providerID, accountID: accountID)
        _ = lock.withLock {
            cooldownUntilByKeyFingerprint.removeValue(forKey: key)
        }
    }

    public func accountCooldownUntil(providerID: UUID, accountID: UUID, now: Date = Date()) -> Date? {
        let key = Self.accountKey(providerID: providerID, accountID: accountID)
        return lock.withLock {
            guard let until = cooldownUntilByKeyFingerprint[key], until > now else {
                return nil
            }
            return until
        }
    }

    private static func accountKey(providerID: UUID, accountID: UUID) -> String {
        "\(providerID.uuidString)|acct|\(accountID.uuidString)"
    }
}
