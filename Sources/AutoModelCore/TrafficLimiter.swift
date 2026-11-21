import Foundation

/// Tracks in-flight per-provider concurrency and per-model sliding 60s request counts
/// so auto-routing can spill traffic to same-tier backups before hitting upstream 429s.
public final class TrafficLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlightByProviderID: [UUID: Int] = [:]
    private var requestTimestampsByModelID: [UUID: [Date]] = [:]

    public init() {}

    public func beginAttempt(providerID: UUID, modelID: UUID, now: Date = Date()) {
        lock.withLock {
            inFlightByProviderID[providerID, default: 0] += 1
            var stamps = requestTimestampsByModelID[modelID] ?? []
            let cutoff = now.addingTimeInterval(-60)
            stamps.removeAll { $0 < cutoff }
            stamps.append(now)
            requestTimestampsByModelID[modelID] = stamps
        }
    }

    public func endAttempt(providerID: UUID) {
        lock.withLock {
            let current = inFlightByProviderID[providerID] ?? 0
            if current <= 1 {
                inFlightByProviderID.removeValue(forKey: providerID)
            } else {
                inFlightByProviderID[providerID] = current - 1
            }
        }
    }

    public func inFlightCount(for providerID: UUID) -> Int {
        lock.withLock { inFlightByProviderID[providerID] ?? 0 }
    }

    public func requestsInLastMinute(for modelID: UUID, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-60)
        return lock.withLock {
            guard var stamps = requestTimestampsByModelID[modelID] else { return 0 }
            stamps.removeAll { $0 < cutoff }
            requestTimestampsByModelID[modelID] = stamps
            return stamps.count
        }
    }

    public func isProviderAtConcurrencyCap(_ provider: ProviderConfig) -> Bool {
        guard let cap = provider.maxConcurrentRequests, cap > 0 else { return false }
        return inFlightCount(for: provider.id) >= cap
    }

    public func isModelAtSoftRPMCap(_ model: ModelConfig, now: Date = Date()) -> Bool {
        guard let rpm = model.maxRequestsPerMinute, rpm > 0 else { return false }
        return requestsInLastMinute(for: model.id, now: now) >= rpm
    }

    public func isSaturated(model: ModelConfig, provider: ProviderConfig, now: Date = Date()) -> Bool {
        isProviderAtConcurrencyCap(provider) || isModelAtSoftRPMCap(model, now: now)
    }

    public func reset() {
        lock.withLock {
            inFlightByProviderID.removeAll()
            requestTimestampsByModelID.removeAll()
        }
    }
}
