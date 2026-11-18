import Foundation

public final class LocalPersistenceStore: @unchecked Sendable {
    public let baseDirectoryURL: URL
    public let configFileURL: URL
    public let historyFileURL: URL
    public let metricsFileURL: URL
    public let budgetLedgerFileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager = FileManager.default
    private let queue: DispatchQueue

    public convenience init(baseDirectoryURL: URL? = nil) {
        self.init(baseDirectoryURL: baseDirectoryURL,
            queue: DispatchQueue(label: "org.automodel.persistence", qos: .utility))
    }

    init(baseDirectoryURL: URL?, queue: DispatchQueue) {
        self.queue = queue
        let resolvedDir: URL
        if let customDir = baseDirectoryURL {
            resolvedDir = customDir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            resolvedDir = appSupport.appendingPathComponent("AutoModel", isDirectory: true)
        }

        self.baseDirectoryURL = resolvedDir
        self.configFileURL = resolvedDir.appendingPathComponent("config.json")
        self.historyFileURL = resolvedDir.appendingPathComponent("history.json")
        self.metricsFileURL = resolvedDir.appendingPathComponent("local-metrics.json")
        self.budgetLedgerFileURL = resolvedDir.appendingPathComponent("budget-ledger.json")

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        try? fileManager.createDirectory(at: resolvedDir, withIntermediateDirectories: true)
    }

    public func loadConfig() -> AppConfigBundle {
        queue.sync {
            guard fileManager.fileExists(atPath: configFileURL.path),
                  let data = try? Data(contentsOf: configFileURL),
                  let bundle = try? decoder.decode(AppConfigBundle.self, from: data) else {
                return AppConfigBundle()
            }
            return bundle
        }
    }

    public func saveConfig(_ bundle: AppConfigBundle) throws {
        try queue.sync {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(bundle)
            try data.write(to: configFileURL, options: .atomic)
        }
    }

    public func loadHistory() -> [CallRecord] {
        queue.sync {
            guard fileManager.fileExists(atPath: historyFileURL.path),
                  let data = try? Data(contentsOf: historyFileURL),
                  let records = try? decoder.decode([CallRecord].self, from: data) else {
                return []
            }
            return records
        }
    }

    public func saveHistory(_ records: [CallRecord]) throws {
        try queue.sync {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
            // Keep most recent 500 records locally to avoid unbounded file growth
            let capped = Array(records.prefix(500))
            let data = try encoder.encode(capped)
            try data.write(to: historyFileURL, options: .atomic)
        }
    }

    public func loadBudgetLedger() -> BudgetLedger? {
        queue.sync {
            guard fileManager.fileExists(atPath: budgetLedgerFileURL.path),
                  let data = try? Data(contentsOf: budgetLedgerFileURL),
                  let ledger = try? decoder.decode(BudgetLedger.self, from: data) else {
                return nil
            }
            return ledger
        }
    }

    public func saveBudgetLedger(_ ledger: BudgetLedger) throws {
        try queue.sync {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(ledger)
            try data.write(to: budgetLedgerFileURL, options: .atomic)
        }
    }

    public func clearBudgetLedger() throws {
        try queue.sync {
            if fileManager.fileExists(atPath: budgetLedgerFileURL.path) {
                try fileManager.removeItem(at: budgetLedgerFileURL)
            }
        }
    }

    public func clearHistory() throws {
        try queue.sync {
            if fileManager.fileExists(atPath: historyFileURL.path) {
                try fileManager.removeItem(at: historyFileURL)
            }
        }
    }

    public func loadOnboardingFunnel() -> LocalOnboardingFunnelState {
        queue.sync {
            guard fileManager.fileExists(atPath: metricsFileURL.path),
                  let data = try? Data(contentsOf: metricsFileURL),
                  let state = try? decoder.decode(LocalOnboardingFunnelState.self, from: data) else {
                return LocalOnboardingFunnelState()
            }
            return state
        }
    }

    public func saveOnboardingFunnel(_ state: LocalOnboardingFunnelState) throws {
        try queue.sync {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            try data.write(to: metricsFileURL, options: .atomic)
        }
    }

    public func clearMetrics() throws {
        try queue.sync {
            if fileManager.fileExists(atPath: metricsFileURL.path) {
                try fileManager.removeItem(at: metricsFileURL)
            }
        }
    }

    private var pendingWriteError: Error?

    // Enqueue synchronously so MainActor snapshot order is also disk order.
    // Encoding and atomic replacement both run on the store's existing serial queue.
    func enqueueCompletionSnapshot(
        config: AppConfigBundle, history: [CallRecord], ledger: BudgetLedger,
        funnel: LocalOnboardingFunnelState,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async {
            do {
                try self.fileManager.createDirectory(at: self.baseDirectoryURL, withIntermediateDirectories: true)
                // Ledger first: a later history/metrics failure must not erase billed usage.
                try self.encoder.encode(ledger).write(to: self.budgetLedgerFileURL, options: .atomic)
                try self.encoder.encode(Array(history.prefix(500))).write(to: self.historyFileURL, options: .atomic)
                try self.encoder.encode(funnel).write(to: self.metricsFileURL, options: .atomic)
                try self.encoder.encode(config).write(to: self.configFileURL, options: .atomic)
                self.pendingWriteError = nil
                completion(.success(()))
            } catch {
                self.pendingWriteError = error
                completion(.failure(error))
            }
        }
    }

    func enqueueConfig(_ config: AppConfigBundle, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                try self.fileManager.createDirectory(at: self.baseDirectoryURL, withIntermediateDirectories: true)
                try self.encoder.encode(config).write(to: self.configFileURL, options: .atomic)
                self.pendingWriteError = nil
                completion(.success(()))
            } catch {
                self.pendingWriteError = error
                completion(.failure(error))
            }
        }
    }

    public func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if let error = self.pendingWriteError { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    /// Exports sanitized routing receipts without any API keys.
    public func exportReceiptsJSON(records: [CallRecord], secretsToRedact: [String]) throws -> Data {
        let data = try queue.sync { try encoder.encode(records) }
        guard let raw = String(data: data, encoding: .utf8) else {
            return data
        }
        let redacted = SecretRedactor.redact(raw, secrets: secretsToRedact)
        return Data(redacted.utf8)
    }
}
