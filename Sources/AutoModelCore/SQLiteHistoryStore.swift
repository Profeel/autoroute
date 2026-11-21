import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct DailyUsageTrendPoint: Identifiable, Equatable, Sendable {
    public var id: String { dayKey }
    public var dayKey: String
    public var callCount: Int
    public var successCount: Int
    public var totalTokens: Int
    public var promptTokens: Int
    public var cachedInputTokens: Int
    public var cacheCreationTokens: Int
    public var totalCostUSD: Double

    public init(
        dayKey: String,
        callCount: Int = 0,
        successCount: Int = 0,
        totalTokens: Int = 0,
        promptTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        totalCostUSD: Double = 0
    ) {
        self.dayKey = dayKey
        self.callCount = callCount
        self.successCount = successCount
        self.totalTokens = totalTokens
        self.promptTokens = promptTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalCostUSD = totalCostUSD
    }

    public var cacheHitRate: Double? {
        let denominator = promptTokens + cachedInputTokens
        guard cachedInputTokens > 0, denominator > 0 else { return nil }
        return min(1.0, Double(cachedInputTokens) / Double(max(promptTokens, cachedInputTokens)))
    }
}

public struct UsageBreakdownItem: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var callCount: Int
    public var successCount: Int
    public var totalTokens: Int
    public var cachedInputTokens: Int
    public var totalCostUSD: Double

    public init(
        key: String,
        label: String,
        callCount: Int,
        successCount: Int,
        totalTokens: Int,
        cachedInputTokens: Int = 0,
        totalCostUSD: Double
    ) {
        self.key = key
        self.label = label
        self.callCount = callCount
        self.successCount = successCount
        self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens
        self.totalCostUSD = totalCostUSD
    }
}

public enum SQLiteHistoryError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case executionFailed(String)
    case prepareFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "无法打开 SQLite 历史库：\(msg)"
        case .executionFailed(let msg): return "SQLite 执行失败：\(msg)"
        case .prepareFailed(let msg): return "SQLite 语句编译失败：\(msg)"
        }
    }
}

/// WAL-backed SQLite store for durable O(1) call record appends and indexed analytics queries.
/// Thread-safety is managed by the owning `LocalPersistenceStore`'s serial queue.
final class SQLiteHistoryStore {
    let databaseURL: URL
    private var db: OpaquePointer?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    deinit {
        close()
    }

    func close() {
        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    private func ensureOpen() throws -> OpaquePointer {
        if let db { return db }
        let parent = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let errMsg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code=\(rc)"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteHistoryError.openFailed(errMsg)
        }

        do {
            try exec(opened, sql: "PRAGMA journal_mode=WAL;")
            try exec(opened, sql: "PRAGMA synchronous=NORMAL;")
            try exec(opened, sql: "PRAGMA busy_timeout=5000;")
            try exec(opened, sql: """
                CREATE TABLE IF NOT EXISTS call_records (
                    id TEXT PRIMARY KEY,
                    timestamp REAL NOT NULL,
                    day_key TEXT NOT NULL,
                    source TEXT NOT NULL,
                    status TEXT NOT NULL,
                    execution_origin TEXT,
                    agent_id TEXT,
                    model_id TEXT,
                    model_display_name TEXT,
                    provider_name TEXT,
                    tier TEXT,
                    session_key TEXT NOT NULL,
                    prompt_tokens INTEGER NOT NULL DEFAULT 0,
                    completion_tokens INTEGER NOT NULL DEFAULT 0,
                    total_tokens INTEGER NOT NULL DEFAULT 0,
                    cached_input_tokens INTEGER NOT NULL DEFAULT 0,
                    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
                    total_cost_usd REAL,
                    total_completion_ms REAL NOT NULL DEFAULT 0,
                    routing_decision_ms REAL NOT NULL DEFAULT 0,
                    payload_json BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_call_records_timestamp ON call_records(timestamp DESC);
                CREATE INDEX IF NOT EXISTS idx_call_records_day_key ON call_records(day_key);
                CREATE INDEX IF NOT EXISTS idx_call_records_agent_id ON call_records(agent_id);
                CREATE INDEX IF NOT EXISTS idx_call_records_model_id ON call_records(model_id);
                CREATE INDEX IF NOT EXISTS idx_call_records_session_key ON call_records(session_key);
                """)
            self.db = opened
            return opened
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }
    }

    private func exec(_ db: OpaquePointer, sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "code=\(rc)"
            sqlite3_free(errMsg)
            throw SQLiteHistoryError.executionFailed(message)
        }
    }

    private static let upsertSQL = """
        INSERT OR REPLACE INTO call_records (
            id, timestamp, day_key, source, status, execution_origin,
            agent_id, model_id, model_display_name, provider_name, tier, session_key,
            prompt_tokens, completion_tokens, total_tokens,
            cached_input_tokens, cache_creation_tokens,
            total_cost_usd, total_completion_ms, routing_decision_ms, payload_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

    private func bindAndStepUpsert(db: OpaquePointer, stmt: OpaquePointer, record: CallRecord, calendar: Calendar) throws {
        let payload = try encoder.encode(record)
        let dayKey = DailyUsageLedger.dayKey(for: record.timestamp, calendar: calendar)
        let promptTokens = Int64(max(0, record.finalUsage?.promptTokens ?? 0))
        let completionTokens = Int64(max(0, record.finalUsage?.completionTokens ?? 0))
        let totalTokens = Int64(max(0, record.finalUsage?.totalTokens ?? 0))
        let cachedTokens = Int64(max(0, record.finalUsage?.cachedInputTokens ?? 0))
        let cacheCreationTokens = Int64(max(0, record.finalUsage?.cacheCreationTokens ?? 0))

        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)

        bindText(stmt, index: 1, value: record.id.uuidString)
        sqlite3_bind_double(stmt, 2, record.timestamp.timeIntervalSince1970)
        bindText(stmt, index: 3, value: dayKey)
        bindText(stmt, index: 4, value: record.source.rawValue)
        bindText(stmt, index: 5, value: record.status.rawValue)
        bindOptionalText(stmt, index: 6, value: record.executionOrigin?.rawValue)
        bindOptionalText(stmt, index: 7, value: record.decision.agentID)
        bindOptionalText(stmt, index: 8, value: record.executedModelID)
        bindOptionalText(stmt, index: 9, value: record.executedModelDisplayName)
        bindOptionalText(stmt, index: 10, value: record.executedProviderName)
        bindOptionalText(stmt, index: 11, value: record.decision.selectedEffort.rawValue)
        bindText(stmt, index: 12, value: record.sessionGroupKey)
        sqlite3_bind_int64(stmt, 13, promptTokens)
        sqlite3_bind_int64(stmt, 14, completionTokens)
        sqlite3_bind_int64(stmt, 15, totalTokens)
        sqlite3_bind_int64(stmt, 16, cachedTokens)
        sqlite3_bind_int64(stmt, 17, cacheCreationTokens)
        if let cost = record.totalCostUSD, cost.isFinite {
            sqlite3_bind_double(stmt, 18, cost)
        } else {
            sqlite3_bind_null(stmt, 18)
        }
        sqlite3_bind_double(stmt, 19, record.totalCompletionMs)
        sqlite3_bind_double(stmt, 20, record.routingDecisionMs)
        _ = payload.withUnsafeBytes { rawBuf in
            sqlite3_bind_blob(stmt, 21, rawBuf.baseAddress, Int32(payload.count), sqliteTransient)
        }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw SQLiteHistoryError.executionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func upsert(_ record: CallRecord, calendar: Calendar = .current) throws {
        let db = try ensureOpen()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteHistoryError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        try bindAndStepUpsert(db: db, stmt: stmt, record: record, calendar: calendar)
    }

    func upsertBatch(_ records: [CallRecord], calendar: Calendar = .current) throws {
        guard !records.isEmpty else { return }
        let db = try ensureOpen()
        try exec(db, sql: "BEGIN IMMEDIATE;")
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw SQLiteHistoryError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for record in records {
                try bindAndStepUpsert(db: db, stmt: stmt, record: record, calendar: calendar)
            }
            try exec(db, sql: "COMMIT;")
        } catch {
            try? exec(db, sql: "ROLLBACK;")
            throw error
        }
    }

    func replaceAll(_ records: [CallRecord], calendar: Calendar = .current) throws {
        let db = try ensureOpen()
        try exec(db, sql: "BEGIN IMMEDIATE;")
        do {
            try exec(db, sql: "DELETE FROM call_records;")
            if !records.isEmpty {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                    throw SQLiteHistoryError.prepareFailed(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(stmt) }
                for record in records {
                    try bindAndStepUpsert(db: db, stmt: stmt, record: record, calendar: calendar)
                }
            }
            try exec(db, sql: "COMMIT;")
        } catch {
            try? exec(db, sql: "ROLLBACK;")
            throw error
        }
    }

    func loadRecent(limit: Int = 500) -> [CallRecord] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        guard let db = try? ensureOpen() else { return [] }
        let sql = "SELECT payload_json FROM call_records ORDER BY timestamp DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(max(1, limit)))
        return decodeRows(stmt: stmt)
    }

    func queryRecords(
        since: Date? = nil,
        until: Date? = nil,
        agentID: String? = nil,
        modelID: String? = nil,
        limit: Int? = nil
    ) -> [CallRecord] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        guard let db = try? ensureOpen() else { return [] }

        var clauses: [String] = []
        if since != nil { clauses.append("timestamp >= ?") }
        if until != nil { clauses.append("timestamp <= ?") }
        if agentID != nil { clauses.append("agent_id = ?") }
        if modelID != nil { clauses.append("model_id = ?") }

        var sql = "SELECT payload_json FROM call_records"
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY timestamp DESC"
        if limit != nil {
            sql += " LIMIT ?"
        }
        sql += ";"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        if let since {
            sqlite3_bind_double(stmt, idx, since.timeIntervalSince1970)
            idx += 1
        }
        if let until {
            sqlite3_bind_double(stmt, idx, until.timeIntervalSince1970)
            idx += 1
        }
        if let agentID {
            bindText(stmt, index: idx, value: agentID)
            idx += 1
        }
        if let modelID {
            bindText(stmt, index: idx, value: modelID)
            idx += 1
        }
        if let limit {
            sqlite3_bind_int64(stmt, idx, Int64(max(1, limit)))
        }
        return decodeRows(stmt: stmt)
    }

    func totalRecordCount() -> Int {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return 0 }
        guard let db = try? ensureOpen() else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM call_records;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func queryDailyTrends(days: Int, now: Date = Date(), calendar: Calendar = .current) -> [DailyUsageTrendPoint] {
        let clampedDays = max(1, min(365, days))
        let todayStart = calendar.startOfDay(for: now)
        let startDate = calendar.date(byAdding: .day, value: -(clampedDays - 1), to: todayStart) ?? todayStart

        var byDay: [String: DailyUsageTrendPoint] = [:]
        if FileManager.default.fileExists(atPath: databaseURL.path), let db = try? ensureOpen() {
            let sql = """
                SELECT day_key,
                       COUNT(*),
                       SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END),
                       SUM(total_tokens),
                       SUM(prompt_tokens),
                       SUM(cached_input_tokens),
                       SUM(cache_creation_tokens),
                       SUM(COALESCE(total_cost_usd, 0))
                FROM call_records
                WHERE timestamp >= ?
                GROUP BY day_key
                ORDER BY day_key ASC;
                """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_double(stmt, 1, startDate.timeIntervalSince1970)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let dayKey = columnText(stmt, index: 0) ?? ""
                    guard !dayKey.isEmpty else { continue }
                    byDay[dayKey] = DailyUsageTrendPoint(
                        dayKey: dayKey,
                        callCount: Int(sqlite3_column_int64(stmt, 1)),
                        successCount: Int(sqlite3_column_int64(stmt, 2)),
                        totalTokens: Int(sqlite3_column_int64(stmt, 3)),
                        promptTokens: Int(sqlite3_column_int64(stmt, 4)),
                        cachedInputTokens: Int(sqlite3_column_int64(stmt, 5)),
                        cacheCreationTokens: Int(sqlite3_column_int64(stmt, 6)),
                        totalCostUSD: sqlite3_column_double(stmt, 7)
                    )
                }
            }
        }

        // Fill contiguous calendar days so charts render cleanly without gaps.
        var series: [DailyUsageTrendPoint] = []
        series.reserveCapacity(clampedDays)
        for offset in 0..<clampedDays {
            guard let dayDate = calendar.date(byAdding: .day, value: offset, to: startDate) else { continue }
            let key = DailyUsageLedger.dayKey(for: dayDate, calendar: calendar)
            series.append(byDay[key] ?? DailyUsageTrendPoint(dayKey: key))
        }
        return series
    }

    func queryBreakdownByAgent(since: Date? = nil) -> [UsageBreakdownItem] {
        queryBreakdown(column: "COALESCE(agent_id, 'direct')", labelColumn: "COALESCE(agent_id, 'direct')", since: since) { key, _ in
            if key == "direct" { return "通用/直连" }
            if let kind = AgentKind(rawValue: key) { return kind.displayName }
            return key
        }
    }

    func queryBreakdownByModel(since: Date? = nil) -> [UsageBreakdownItem] {
        queryBreakdown(
            column: "COALESCE(model_id, 'unknown')",
            labelColumn: "COALESCE(model_display_name, model_id, '未执行')",
            since: since
        ) { _, label in
            label
        }
    }

    private func queryBreakdown(
        column: String,
        labelColumn: String,
        since: Date?,
        formatLabel: (String, String) -> String
    ) -> [UsageBreakdownItem] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        guard let db = try? ensureOpen() else { return [] }
        let whereClause = since != nil ? "WHERE timestamp >= ?" : ""
        let sql = """
            SELECT \(column) AS group_key,
                   MAX(\(labelColumn)) AS group_label,
                   COUNT(*) AS call_count,
                   SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) AS success_count,
                   SUM(total_tokens) AS total_tokens,
                   SUM(cached_input_tokens) AS cached_tokens,
                   SUM(COALESCE(total_cost_usd, 0)) AS total_cost
            FROM call_records
            \(whereClause)
            GROUP BY group_key
            ORDER BY total_cost DESC, call_count DESC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let since {
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        }
        var items: [UsageBreakdownItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = columnText(stmt, index: 0) ?? "unknown"
            let rawLabel = columnText(stmt, index: 1) ?? key
            items.append(UsageBreakdownItem(
                key: key,
                label: formatLabel(key, rawLabel),
                callCount: Int(sqlite3_column_int64(stmt, 2)),
                successCount: Int(sqlite3_column_int64(stmt, 3)),
                totalTokens: Int(sqlite3_column_int64(stmt, 4)),
                cachedInputTokens: Int(sqlite3_column_int64(stmt, 5)),
                totalCostUSD: sqlite3_column_double(stmt, 6)
            ))
        }
        return items
    }

    @discardableResult
    func prune(olderThanDays: Int, now: Date = Date()) throws -> Int {
        guard olderThanDays > 0 else { return 0 }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return 0 }
        let db = try ensureOpen()
        let cutoff = now.addingTimeInterval(-Double(olderThanDays) * 86_400)
        var stmt: OpaquePointer?
        let sql = "DELETE FROM call_records WHERE timestamp < ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteHistoryError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteHistoryError.executionFailed(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }

    func clearAll() throws {
        close()
        let fm = FileManager.default
        let candidates = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    private func decodeRows(stmt: OpaquePointer) -> [CallRecord] {
        var result: [CallRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ptr = sqlite3_column_blob(stmt, 0) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, 0))
            guard length > 0 else { continue }
            let data = Data(bytes: ptr, count: length)
            if let record = try? decoder.decode(CallRecord.self, from: data) {
                result.append(record)
            }
        }
        return result
    }

    private func bindText(_ stmt: OpaquePointer, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer, index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }
}
