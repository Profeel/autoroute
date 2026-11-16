import Foundation

public final class LocalPersistenceStore: @unchecked Sendable {
    public let baseDirectoryURL: URL
    public let configFileURL: URL
    public let historyFileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "org.automodel.persistence", qos: .utility)

    public init(baseDirectoryURL: URL? = nil) {
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

    public func clearHistory() throws {
        try queue.sync {
            if fileManager.fileExists(atPath: historyFileURL.path) {
                try fileManager.removeItem(at: historyFileURL)
            }
        }
    }

    /// Exports sanitized routing receipts without any API keys.
    public func exportReceiptsJSON(records: [CallRecord], secretsToRedact: [String]) throws -> Data {
        let data = try encoder.encode(records)
        guard let raw = String(data: data, encoding: .utf8) else {
            return data
        }
        let redacted = SecretRedactor.redact(raw, secrets: secretsToRedact)
        return Data(redacted.utf8)
    }
}
