import Foundation

public final class LocalPersistenceStore: @unchecked Sendable {
    public let baseDirectoryURL: URL
    public let configFileURL: URL
    public let historyFileURL: URL
    public let historyDBFileURL: URL
    public let metricsFileURL: URL
    public let budgetLedgerFileURL: URL
    public let dailyUsageLedgerFileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager = FileManager.default
    private let queue: DispatchQueue
    private let sqliteStore: SQLiteHistoryStore

    private var lastHistoryJSONWriteAt: Date = .distantPast
    private var pendingHistoryJSONMirror: [CallRecord]?
    private var pendingMirrorCompletion: (@Sendable (Result<Void, Error>) -> Void)?
    private var historyMirrorWorkItem: DispatchWorkItem?
    private let historyMirrorCoalesceSeconds: TimeInterval = 1.5

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
        self.historyDBFileURL = resolvedDir.appendingPathComponent("history.sqlite")
        self.metricsFileURL = resolvedDir.appendingPathComponent("local-metrics.json")
        self.budgetLedgerFileURL = resolvedDir.appendingPathComponent("budget-ledger.json")
        self.dailyUsageLedgerFileURL = resolvedDir.appendingPathComponent("daily-usage-ledger.json")
        self.sqliteStore = SQLiteHistoryStore(databaseURL: resolvedDir.appendingPathComponent("history.sqlite"))

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

    public func loadHistory(limit: Int = 500) -> [CallRecord] {
        queue.sync {
            if fileManager.fileExists(atPath: historyDBFileURL.path) {
                return sqliteStore.loadRecent(limit: limit)
            }
            guard fileManager.fileExists(atPath: historyFileURL.path),
                  let data = try? Data(contentsOf: historyFileURL),
                  let records = try? decoder.decode([CallRecord].self, from: data) else {
                return []
            }
            // One-time migration from legacy history.json into WAL-backed SQLite store.
            if !records.isEmpty {
                try? sqliteStore.upsertBatch(records)
            }
            return Array(records.prefix(limit))
        }
    }

    public func saveHistory(_ records: [CallRecord]) throws {
        try queue.sync {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
            try sqliteStore.replaceAll(records)
            // Keep most recent 500 records in the JSON compatibility mirror.
            let capped = Array(records.prefix(500))
            let data = try encoder.encode(capped)
            try data.write(to: historyFileURL, options: .atomic)
            self.lastHistoryJSONWriteAt = Date()
            self.pendingHistoryJSONMirror = nil
            self.pendingMirrorCompletion = nil
            self.historyMirrorWorkItem?.cancel()
            self.historyMirrorWorkItem = nil
        }
    }

    public func queryHistoryRecords(
        since: Date? = nil,
        until: Date? = nil,
        agentID: String? = nil,
        modelID: String? = nil,
        limit: Int? = nil
    ) -> [CallRecord] {
        queue.sync {
            ensureSQLiteMigratedIfNeededOnQueue()
            return sqliteStore.queryRecords(
                since: since,
                until: until,
                agentID: agentID,
                modelID: modelID,
                limit: limit
            )
        }
    }

    public func totalStoredRecordCount() -> Int {
        queue.sync {
            ensureSQLiteMigratedIfNeededOnQueue()
            return sqliteStore.totalRecordCount()
        }
    }

    public func queryDailyTrends(days: Int, now: Date = Date(), calendar: Calendar = .current) -> [DailyUsageTrendPoint] {
        queue.sync {
            ensureSQLiteMigratedIfNeededOnQueue()
            return sqliteStore.queryDailyTrends(days: days, now: now, calendar: calendar)
        }
    }

    public func queryBreakdownByAgent(since: Date? = nil) -> [UsageBreakdownItem] {
        queue.sync {
            ensureSQLiteMigratedIfNeededOnQueue()
            return sqliteStore.queryBreakdownByAgent(since: since)
        }
    }

    public func queryBreakdownByModel(since: Date? = nil) -> [UsageBreakdownItem] {
        queue.sync {
            ensureSQLiteMigratedIfNeededOnQueue()
            return sqliteStore.queryBreakdownByModel(since: since)
        }
    }

    @discardableResult
    public func pruneHistory(olderThanDays: Int, now: Date = Date()) throws -> Int {
        try queue.sync {
            try sqliteStore.prune(olderThanDays: olderThanDays, now: now)
        }
    }

    private func ensureSQLiteMigratedIfNeededOnQueue() {
        guard !fileManager.fileExists(atPath: historyDBFileURL.path),
              fileManager.fileExists(atPath: historyFileURL.path),
              let data = try? Data(contentsOf: historyFileURL),
              let records = try? decoder.decode([CallRecord].self, from: data),
              !records.isEmpty else {
            return
        }
        try? sqliteStore.upsertBatch(records)
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

    public func loadDailyUsageLedger() -> DailyUsageLedger? {
        queue.sync {
            guard fileManager.fileExists(atPath: dailyUsageLedgerFileURL.path),
                  let data = try? Data(contentsOf: dailyUsageLedgerFileURL),
                  let ledger = try? decoder.decode(DailyUsageLedger.self, from: data) else {
                return nil
            }
            return ledger
        }
    }

    public func saveDailyUsageLedger(_ ledger: DailyUsageLedger) throws {
        try queue.sync {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(ledger)
            try data.write(to: dailyUsageLedgerFileURL, options: .atomic)
        }
    }

    public func clearDailyUsageLedger() throws {
        try queue.sync {
            if fileManager.fileExists(atPath: dailyUsageLedgerFileURL.path) {
                try fileManager.removeItem(at: dailyUsageLedgerFileURL)
            }
        }
    }

    public func clearHistory() throws {
        try queue.sync {
            self.historyMirrorWorkItem?.cancel()
            self.historyMirrorWorkItem = nil
            self.pendingHistoryJSONMirror = nil
            self.pendingMirrorCompletion = nil
            try sqliteStore.clearAll()
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

    private var pendingSnapshotError: Error?
    private var pendingConfigError: Error?

    // Enqueue synchronously so MainActor snapshot order is also disk order.
    // SQLite receives an O(1) row upsert on every turn while the legacy JSON mirror
    // is coalesced during high-frequency bursts and flushed deterministically on `flush()`.
    func enqueueCompletionSnapshot(
        config: AppConfigBundle, history: [CallRecord], ledger: BudgetLedger,
        dailyUsage: DailyUsageLedger,
        funnel: LocalOnboardingFunnelState,
        changedRecords: [CallRecord] = [],
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async {
            do {
                try self.fileManager.createDirectory(at: self.baseDirectoryURL, withIntermediateDirectories: true)
                // Ledgers & SQLite O(1) append first: a later mirror/metrics failure must not erase billed usage.
                try self.encoder.encode(ledger).write(to: self.budgetLedgerFileURL, options: .atomic)
                try self.encoder.encode(dailyUsage).write(to: self.dailyUsageLedgerFileURL, options: .atomic)
                if !changedRecords.isEmpty {
                    if changedRecords.count == 1, let only = changedRecords.first {
                        try self.sqliteStore.upsert(only)
                    } else {
                        try self.sqliteStore.upsertBatch(changedRecords)
                    }
                } else if let head = history.first {
                    try self.sqliteStore.upsert(head)
                }

                let now = Date()
                let shouldWriteJSONNow = now.timeIntervalSince(self.lastHistoryJSONWriteAt) >= self.historyMirrorCoalesceSeconds
                    || self.pendingSnapshotError != nil
                if shouldWriteJSONNow {
                    self.historyMirrorWorkItem?.cancel()
                    self.historyMirrorWorkItem = nil
                    self.pendingHistoryJSONMirror = nil
                    self.pendingMirrorCompletion = nil
                    try self.encoder.encode(Array(history.prefix(500))).write(to: self.historyFileURL, options: .atomic)
                    self.lastHistoryJSONWriteAt = now
                } else {
                    self.pendingHistoryJSONMirror = Array(history.prefix(500))
                    self.pendingMirrorCompletion = completion
                    self.scheduleHistoryMirrorFlushOnQueue()
                }

                try self.encoder.encode(funnel).write(to: self.metricsFileURL, options: .atomic)
                try self.encoder.encode(config).write(to: self.configFileURL, options: .atomic)
                self.pendingSnapshotError = nil
                self.pendingConfigError = nil
                completion(.success(()))
            } catch {
                self.pendingSnapshotError = error
                completion(.failure(error))
            }
        }
    }

    private func scheduleHistoryMirrorFlushOnQueue() {
        historyMirrorWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingHistoryMirrorOnQueue()
        }
        historyMirrorWorkItem = workItem
        queue.asyncAfter(deadline: .now() + historyMirrorCoalesceSeconds, execute: workItem)
    }

    private func flushPendingHistoryMirrorOnQueue() {
        historyMirrorWorkItem?.cancel()
        historyMirrorWorkItem = nil
        guard let pending = pendingHistoryJSONMirror else { return }
        let completion = pendingMirrorCompletion
        pendingHistoryJSONMirror = nil
        pendingMirrorCompletion = nil
        do {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
            try encoder.encode(pending).write(to: historyFileURL, options: .atomic)
            lastHistoryJSONWriteAt = Date()
            completion?(.success(()))
        } catch {
            pendingSnapshotError = error
            completion?(.failure(error))
        }
    }

    func enqueueConfig(_ config: AppConfigBundle, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                try self.fileManager.createDirectory(at: self.baseDirectoryURL, withIntermediateDirectories: true)
                try self.encoder.encode(config).write(to: self.configFileURL, options: .atomic)
                self.pendingConfigError = nil
                completion(.success(()))
            } catch {
                self.pendingConfigError = error
                completion(.failure(error))
            }
        }
    }

    public func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.flushPendingHistoryMirrorOnQueue()
                if let error = self.pendingSnapshotError ?? self.pendingConfigError { continuation.resume(throwing: error) }
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
