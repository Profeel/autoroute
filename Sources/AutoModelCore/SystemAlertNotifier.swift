import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

public enum SystemAlertCategory: String, Codable, Equatable, Sendable {
    case budgetWarning = "budget_warning"
    case budgetHardLimit = "budget_hard_limit"
    case providerAuthFailure = "provider_auth_failure"
    case tierDegraded = "tier_degraded"
    case portConflict = "port_conflict"
}

public struct SystemAlertEvent: Equatable, Sendable {
    public var category: SystemAlertCategory
    public var dedupKey: String
    public var title: String
    public var body: String
    public var timestamp: Date

    public init(
        category: SystemAlertCategory,
        dedupKey: String,
        title: String,
        body: String,
        timestamp: Date = Date()
    ) {
        self.category = category
        self.dedupKey = dedupKey
        self.title = title
        self.body = body
        self.timestamp = timestamp
    }
}

public protocol SystemAlertNotifierProtocol: Sendable {
    func notify(_ event: SystemAlertEvent)
}

public final class NoOpSystemAlertNotifier: SystemAlertNotifierProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SystemAlertEvent] = []

    public init() {}

    public func notify(_ event: SystemAlertEvent) {
        lock.withLock { recorded.append(event) }
    }

    public var events: [SystemAlertEvent] {
        lock.withLock { recorded }
    }
}

/// Throttled macOS notification dispatcher safe in both `.app` bundles and headless/test processes.
public final class MacOSSystemAlertNotifier: SystemAlertNotifierProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var lastSentAtByKey: [String: Date] = [:]
    private let throttleSeconds: TimeInterval
    private var authorizationRequested = false

    public init(throttleSeconds: TimeInterval = 900) {
        self.throttleSeconds = max(0, throttleSeconds)
    }

    public func shouldDeliver(event: SystemAlertEvent) -> Bool {
        let compositeKey = "\(event.category.rawValue)|\(event.dedupKey)"
        return lock.withLock {
            if let last = lastSentAtByKey[compositeKey],
               event.timestamp.timeIntervalSince(last) < throttleSeconds {
                return false
            }
            lastSentAtByKey[compositeKey] = event.timestamp
            return true
        }
    }

    public func notify(_ event: SystemAlertEvent) {
        guard shouldDeliver(event: event) else { return }
        #if canImport(UserNotifications)
        // Guard strictly against non-bundle (CLI / `swift test`) invocations where UNUserNotificationCenter throws.
        guard Bundle.main.bundleURL.pathExtension == "app",
              let bundleID = Bundle.main.bundleIdentifier,
              !bundleID.isEmpty else {
            return
        }
        let center = UNUserNotificationCenter.current()
        let needsAuthRequest = lock.withLock { () -> Bool in
            if authorizationRequested { return false }
            authorizationRequested = true
            return true
        }
        let sendBlock: @Sendable () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "autoroute.\(event.category.rawValue).\(event.dedupKey)",
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
        if needsAuthRequest {
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { sendBlock() }
            }
        } else {
            center.getNotificationSettings { settings in
                if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                    sendBlock()
                }
            }
        }
        #endif
    }
}
